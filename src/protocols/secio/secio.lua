-- prevent wireshark loading this file as a plugin
if not _G['secio_dissector'] then return end

local pb = require ("pb")
local SecioState = require ("secio_state")
local utils = require ("secio_misc")

secio_proto = Proto("secio", "SECIO protocol")

local fields = secio_proto.fields

-- field related to secio packet size
fields.packet_len = ProtoField.uint32 ("secio.packet_size", "Packet size", base.HEX, nil, 0, "Secio packet size in bytes")

-- fields related to Propose packets type
fields.propose = ProtoField.bytes ("secio.propose", "Propose", base.NONE, nil, 0, "Propose request")
fields.rand = ProtoField.bytes ("secio.propose.rand", "rand", base.NONE, nil, 0, "Propose random bytes")
fields.pubkey = ProtoField.bytes ("secio.propose.pubkey", "pubkey", base.NONE, nil, 0, "Propose public key")
fields.exchanges = ProtoField.string ("secio.propose.exchanges", "exchanges", base.NONE, nil, 0, "Propose exchanges")
fields.ciphers = ProtoField.string ("secio.propose.ciphers", "ciphers", base.NONE, nil, 0, "Propose ciphers")
fields.hashes = ProtoField.string ("secio.propose.hashes", "hashes", base.NONE, nil, 0, "Propose hashes")

-- fields related to Exchange packets type
fields.exchange = ProtoField.bytes ("secio.exchange", "exchange", base.NONE, nil, 0, "Exchange request")
fields.epubkey = ProtoField.bytes ("secio.exchange.epubkey", "epubkey", base.NONE, nil, 0, "Ephermal public key")
fields.signature = ProtoField.bytes ("secio.exchange.signature", "signature", base.NONE, nil, 0, "Exchange signature")

-- fields related to Body packets type
fields.cipher_text = ProtoField.bytes ("secio.body.cipher_text", "cipher text", base.NONE, nil, 0, "Cipher text")
fields.hmac = ProtoField.bytes ("secio.body.hmac", "HMAC", base.NONE, nil, 0, "HMAC of cipher text")

local function dissect_handshake(buffer, pinfo)
    local is_listener = false

    -- heuristic multistream detector should already set MSState.listener and MSState.dialer fields
    if (is_same_src_address(SecioState.listener, pinfo)) then
        is_listener = true
    elseif (not is_same_src_address(SecioState.dialer, pinfo)) then
        -- some error occured
        print("multistream dissector: ip:port are incorrect")
        return
    end

    if(is_listener) then
        if (SecioState.listenerProposePacketId == -1) then
            SecioState.listenerProposePacketId = pinfo.number
        elseif (SecioState.listenerExchangePacketId == -1) then
            SecioState.listenerExchangePacketId = pinfo.number
        end
    else
        if (SecioState.dialerProposePacketId == -1) then
            SecioState.dialerProposePacketId = pinfo.number
        elseif (SecioState.dialerExchangePacketId == -1) then
            SecioState.dialerExchangePacketId = pinfo.number
        end
    end

    if (
        SecioState.listenerProposePacketId ~= -1 and
        SecioState.dialerProposePacketId ~= -1 and
        SecioState.listenerExchangePacketId ~= -1 and
        SecioState.dialerExchangePacketId ~= -1
    ) then
        SecioState.handshaked = true
    end
end

local function parse_and_set_propose(buffer, tree)
    tree:add(fields.packet_len, buffer(0, 4))
    local branch = tree:add("Propose", fields.propose)

    local propose = assert(pb.decode("Propose", buffer:raw(4, -1)))
    local offset = 4

    -- check for fields presence and add them to the tree
    if (propose.rand ~= nil) then
        branch:add(fields.rand, buffer(offset, propose.rand:len() + 3))
        offset = offset + propose.rand:len() + 3
    end

    if (propose.pubkey ~= nil) then
        branch:add(fields.pubkey, buffer(offset, propose.pubkey:len() + 4))
        offset = offset + propose.pubkey:len() + 4
    end

    if (propose.exchanges ~= nil) then
        branch:add(fields.exchanges, buffer(offset, propose.exchanges:len()))
        offset = offset + propose.exchanges:len()
    end

    if (propose.ciphers ~= nil) then
        branch:add(fields.ciphers, buffer(offset + 2, propose.ciphers:len()))
        offset = offset + propose.ciphers:len()
    end

    if (propose.hashes ~= nil) then
        branch:add(fields.hashes, buffer(offset + 4, propose.hashes:len()))
        offset = offset + propose.hashes:len()
    end
end

local function parse_and_set_exchange(buffer, tree)
    tree:add(fields.packet_len, buffer(0, 4))
    local branch = tree:add("Exchange", fields.exchange)

    local exchange = assert(pb.decode("Exchange", buffer:raw(4, -1)))
    local offset = 4

    -- check for fields presence and add them to the tree
    if (exchange.epubkey ~= nil) then
        branch:add(fields.epubkey, buffer(offset, exchange.epubkey:len() + 2))
        offset = offset + exchange.epubkey:len() + 2
    end

    if (exchange.signature ~= nil) then
        branch:add(fields.signature, buffer(offset, exchange.signature:len() + 2))
        offset = offset + exchange.signature:len() + 2
    end
end

function secio_proto.dissector (buffer, pinfo, tree)
    -- the message should be at least 4 bytes
    if buffer:len() < 4 then
        return
    end

    if (next(SecioState.listener) == nil) then
        SecioState:init_with_private(pinfo.private)
    end

    local subtree = tree:add(secio_proto, "SECIO protocol")
    pinfo.cols.protocol = secio_proto.name

    if (not SecioState.handshaked) then
        dissect_handshake(buffer, pinfo)
    end

    -- according to the spec, first 4 bytes always represent packet size
    local packet_len = buffer(0, 4):uint()

    if (SecioState.listenerProposePacketId == pinfo.number) then
        pinfo.cols.info = "SECIO: Propose (listener)"
        parse_and_set_propose(buffer, subtree)
    elseif (SecioState.dialerProposePacketId == pinfo.number) then
        pinfo.cols.info = "SECIO: Propose (dialer)"
        parse_and_set_propose(buffer, subtree)
    elseif (SecioState.listenerExchangePacketId == pinfo.number) then
        pinfo.cols.info = "SECIO Exchange (listener)"
        parse_and_set_exchange(buffer, subtree)
    elseif (SecioState.dialerExchangePacketId == pinfo.number) then
        pinfo.cols.info = "SECIO Exchange (dialer)"
        parse_and_set_exchange(buffer, subtree)
    elseif (SecioState.handshaked) then
        -- encrypted packets

        if (next(SecioState.cryptoParams) == nil) then
            SecioState:init_crypto_params(pinfo)
        end

        pinfo.cols.info = "SECIO Body"
        local plain_text = ""
        local hmac_type = SecioState.listenerHMACType
        local hmac_size = utils:hashSize(SecioState.listenerHMACType)

        -- if see this packet for the first time, we need to decrypt it
        if not pinfo.visited then
            -- [4 bytes len][ cipher_text ][ H(cipher_text) ]
            if (is_same_src_address(SecioState.listener, pinfo)) then
                plain_text = SecioState.listenerMsgDecryptor(buffer:raw(4, packet_len - hmac_size))
            else
                hmac_type = SecioState.dialerHMACType
                hmac_size = utils:hashSize(SecioState.dialerHMACType)
                plain_text = SecioState.dialerMsgDecryptor(buffer:raw(4, packet_len - hmac_size))
            end

            SecioState.decryptedPayloads[pinfo.number] = plain_text
        else
            plain_text = SecioState.decryptedPayloads[pinfo.number]
        end

        local offset = 0
        subtree:add(fields.packet_len, buffer(offset, 4))
        offset = offset + 4

        plain_text = Struct.tohex(tostring(plain_text))
        subtree:add(buffer(offset, packet_len - hmac_size),
            string.format("cipher text 0x%X bytes: (plain text is %s )", #plain_text, plain_text)
        )
        offset = offset + packet_len - hmac_size

        subtree:add(fields.hmac, buffer(offset, -1)):append_text(string.format("(%s)", hmac_type))

        pinfo.private["plain_text"] = plain_text
        Dissector.get("mplex"):call(buffer, pinfo, tree)
    end
end

return secio_proto
