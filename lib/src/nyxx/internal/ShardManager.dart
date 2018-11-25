part of nyxx;

/// The WS manager for the client.
class _ShardManager {
  Nyxx _client;

  /// The base websocket URL.
  String gateway;

  final Logger logger = Logger("Shards");

  Map<int, Shard> _shards;

  /// Makes a new WS manager.
  _ShardManager(this._client) {
    _shards = Map();
    _client._http._headers['Authorization'] = "Bot ${_client._token}";
    _client._http.send("GET", "/gateway/bot").then((HttpResponse r) {
      this.gateway = r.body['url'] as String;

      if(_client._options.shardCount > 1) {
        connectShard(0, _client._options.shardCount);
      } else {
        var shardNumber = r.body['shards'] as int;

        connectShard(0, shardNumber);
      }

      _client._events.onReady.add(ReadyEvent._new(_client));
    });
  }

  void connectShard(int i, int maxShard) {
    _shards[i] = Shard(this, i);

    if(i + 1 < maxShard)
      Future.delayed(Duration(seconds: 6), () => connectShard(i + 1, maxShard));
  }

}

// Decodes zlib compresses string into string json
Map<String, dynamic> _decodeBytes(dynamic bytes) {
  if (bytes is String) return jsonDecode(bytes) as Map<String, dynamic>;

  var decoded = zlib.decoder.convert(bytes as List<int>);
  var rawStr = utf8.decode(decoded);
  return jsonDecode(rawStr) as Map<String, dynamic>;
}

Future shardThread(SendPort port) async {
  transport.WebSocket _websocket;

  var recv = ReceivePort();
  port.send(recv.sendPort);

  await for(var data in recv) {
    if(data is Map<String, dynamic>) {
      _websocket.add(jsonEncode(data));
      continue;
    }

    if(data is List<String>) {
      if (data.first == "CONNECT") {
        configureWTransportForVM();
        transport.WebSocket.connect(Uri.parse("${data[1]}?v=7&encoding=json"))
            .then((ws) {
          _websocket = ws;

          print("CONNECTED");

          Future(() {
            _websocket.listen((d) {
              port.send(_decodeBytes(d));
            });
          });
        });
      }
    }
  }
}

class Shard {
  _ShardManager _shardManager;
  Isolate shardIsolate;

  SendPort isolateSendPort;
  ReceivePort isolateReceivePort;

  int _sequence = 0;
  String _sessionId;
  Timer _heartbeatTimer;

  int id;
  bool ready;
  int messagesReceived = 0;

  Shard(this._shardManager, this.id) {
    isolateReceivePort = ReceivePort();

    Isolate.spawn(shardThread, isolateReceivePort.sendPort).then((isolate) {
      shardIsolate = isolate;
      shardIsolate.setErrorsFatal(false);
    });

    isolateReceivePort.listen((data) {
      if(data is Map<String, dynamic>) {
        Future.microtask(() => dispatchEvent(data, false));
      }

      if(data is SendPort) {
        isolateSendPort = data;
        isolateSendPort.send(["CONNECT", this._shardManager.gateway]);
      }
    });
  }

  void send(String op, dynamic d) =>
    this.isolateSendPort.send(<String, dynamic>{"op": _OPCodes.matchOpCode(op), "d": d});

  void _heartbeat() {
    //if (this._socket.closeCode != null) return;
    this.send("HEARTBEAT", _sequence);
  }

  Future<void> dispatchEvent(Map<String, dynamic> msg, bool resume) async {
    //_shardManager._client._events.onRaw.add(RawEvent._new(this, msg));

    if (msg['s'] != null) this._sequence = msg['s'] as int;

    switch (msg['op'] as int) {
      case _OPCodes.HELLP:
        if (this._sessionId == null || !resume) {
          Map<String, dynamic> identifyMsg = <String, dynamic>{
            "token": _shardManager._client._token,
            "properties": <String, dynamic>{
              "\$os": operatingSystem,
              "\$browser": "nyxx",
              "\$device": "nyxx",
            },
            "large_threshold": this._shardManager._client._options.largeThreshold,
            "compress": !browser
          };

          identifyMsg['shard'] = <int>[this.id, _shardManager._client._options.shardCount];
          this.send("IDENTIFY", identifyMsg);
        } else if (resume) {
          this.send("RESUME", <String, dynamic>{
            "token": _shardManager._client._token,
            "session_id": this._sessionId,
            "seq": this._sequence
          });
        }

        this._heartbeatTimer = Timer.periodic(
            Duration(milliseconds: msg['d']['heartbeat_interval'] as int),
                (Timer t) => this._heartbeat());

        break;

      case _OPCodes.INVALID_SESSION:
        exit(123);
        /*_logger.severe("Invalid session on shard [$id]. Reconnecting...");
        _heartbeatTimer.cancel();
        _shardManager._client._events.onDisconnect.add(DisconnectEvent._new(this, 9));
        this._onDisconnect.add(this);

        if (msg['d'] as bool) {
          Timer(Duration(seconds: 2), () => _connect(true));
        } else {
          Timer(Duration(seconds: 6), () => _connect(false, true));
        }
        */
        break;

      case _OPCodes.DISPATCH:
        var j = msg['t'] as String;
        switch (j) {
          case 'READY':
            this._sessionId = msg['d']['session_id'] as String;
            _shardManager._client.self =
                ClientUser._new(msg['d']['user'] as Map<String, dynamic>, _shardManager._client);

            _shardManager._client._http._headers['Authorization'] = "Bot ${_shardManager._client._token}";
            if(!browser)
              _shardManager._client._http._headers['User-Agent'] =
              "${_shardManager._client.self.username} (${_Constants.repoUrl}, ${_Constants.version})";

            this.ready = true;
            //this._onReady.add(this);
            //_logger.info("Shard [$id] connected");

            break;

          case 'GUILD_MEMBERS_CHUNK':
            msg['d']['members'].forEach((dynamic o) {
              var mem = _StandardMember(o as Map<String, dynamic>,
                  _shardManager._client.guilds[Snowflake(msg['d']['guild_id'])], _shardManager._client);
              _shardManager._client.users.add(mem);
              mem.guild.members.add(mem);
            });

            //if (!_shardManager._client.ready) _shardManager.testReady();
            break;

          case 'MESSAGE_REACTION_REMOVE_ALL':
            var m = MessageReactionsRemovedEvent._new(msg, _shardManager._client);

            if(m.message != null) {
              _shardManager._client._events.onMessageReactionsRemoved.add(m);
              _shardManager._client._events.onMessage.add(m);
            }
            break;

          case 'MESSAGE_REACTION_ADD':
            var m = MessageReactionEvent._new(msg, _shardManager._client);
            if(m.message != null) {
              _shardManager._client._events.onMessageReactionAdded.add(m);
              _shardManager._client._events.onMessage.add(m);
              m.message._onReactionAdded.add(m);
            }
            break;

          case 'MESSAGE_REACTION_REMOVE':
            var m = MessageReactionEvent._new(msg, _shardManager._client);

            if(m.message != null) {
              m.message._onReactionAdded.add(m);
              _shardManager._client._events.onMessageReactionAdded.add(m);
            }
            break;

          case 'MESSAGE_DELETE_BULK':
            MessageDeleteBulkEvent._new(msg, _shardManager._client);
            break;

          case 'CHANNEL_PINS_UPDATE':
            var m = ChannelPinsUpdateEvent._new(msg, _shardManager._client);

            if(m.channel != null)
              m.channel._pinsUpdated.add(m);
            _shardManager._client._events.onChannelPinsUpdate.add(m);
            break;

          case 'VOICE_STATE_UPDATE':
            _shardManager._client._events.onVoiceStateUpdate
                .add(VoiceStateUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'VOICE_SERVER_UPDATE':
            _shardManager._client._events.onVoiceServerUpdate
                .add(VoiceServerUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_EMOJIS_UPDATE':
            _shardManager._client._events.onGuildEmojisUpdate
                .add(GuildEmojisUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'MESSAGE_CREATE':
            messagesReceived++;
            var m = MessageReceivedEvent._new(msg, _shardManager._client);
            if(m.message == null)
              break;

            _shardManager._client._events.onMessage.add(m);
            _shardManager._client._events.onMessageReceived.add(m);

            if(m.message.channel != null) {
              m.message.channel._onMessage.add(m);
            }
            break;

          case 'MESSAGE_DELETE':
            var m = MessageDeleteEvent._new(msg, _shardManager._client);
            _shardManager._client._events.onMessage.add(m);
            _shardManager._client._events.onMessageDelete.add(m);
            break;

          case 'MESSAGE_UPDATE':
            var m = MessageUpdateEvent._new(msg, _shardManager._client);

            if (m.oldMessage != null)
              _shardManager._client._events.onMessageUpdate.add(m);
            break;

          case 'GUILD_CREATE':
            _shardManager._client._events.onGuildCreate.add(GuildCreateEvent._new(msg, this, _shardManager._client));
            break;

          case 'GUILD_UPDATE':
            _shardManager._client._events.onGuildUpdate.add(GuildUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_DELETE':
            if (msg['d']['unavailable'] == true) {
            }
            //_shardManager._client._events.onGuildUnavailable.add(GuildUnavailableEvent._new(msg));
            else
              GuildDeleteEvent._new(msg, this, _shardManager._client);
            break;

          case 'GUILD_BAN_ADD':
            _shardManager._client._events.onGuildBanAdd.add(GuildBanAddEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_BAN_REMOVE':
            _shardManager._client._events.onGuildBanRemove.add(GuildBanRemoveEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_MEMBER_ADD':
            _shardManager._client._events.onGuildMemberAdd.add(GuildMemberAddEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_MEMBER_REMOVE':
            _shardManager._client._events.onGuildMemberRemove
                .add(GuildMemberRemoveEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_MEMBER_UPDATE':
            _shardManager._client._events.onGuildMemberUpdate
                .add(GuildMemberUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'CHANNEL_CREATE':
            _shardManager._client._events.onChannelCreate.add(ChannelCreateEvent._new(msg, _shardManager._client));
            break;

          case 'CHANNEL_UPDATE':
            _shardManager._client._events.onChannelUpdate.add(ChannelUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'CHANNEL_DELETE':
            _shardManager._client._events.onChannelDelete.add(ChannelDeleteEvent._new(msg, _shardManager._client));
            break;

          case 'TYPING_START':
            var m = TypingEvent._new(msg, _shardManager._client);

            _shardManager._client._events.onTyping.add(m);
            if(m.channel != null)
              m.channel._onTyping.add(m);
            break;

          case 'PRESENCE_UPDATE':
            _shardManager._client._events.onPresenceUpdate.add(PresenceUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_ROLE_CREATE':
            _shardManager._client._events.onRoleCreate.add(RoleCreateEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_ROLE_UPDATE':
            _shardManager._client._events.onRoleUpdate.add(RoleUpdateEvent._new(msg, _shardManager._client));
            break;

          case 'GUILD_ROLE_DELETE':
            _shardManager._client._events.onRoleDelete.add(RoleDeleteEvent._new(msg, _shardManager._client));
            break;

          case 'USER_UPDATE':
            _shardManager._client._events.onUserUpdate.add(UserUpdateEvent._new(msg, _shardManager._client));
            break;

          default:
            print("UNKNOWN OPCODE: ${jsonEncode(msg)}");
        }
        break;
    }
  }
}

/*void setupShard(int shardId) {
    Shard shard = Shard._new(this, shardId);
    _client.shard = shard;

    shard.onReady.listen((Shard s) {
      if (!_client.ready) {
        testReady();
      }
    });
  }

  void connectShard(int index) {
    _client.shard._connect(false, true);
  }

  void testReady() {
    bool match1() {
      for (var o in _client.guilds.values) {
        if (_client._options.forceFetchMembers && o.members.count !=
            o.memberCount) {
          return false;
        }
      }

      return true;
    }

    bool match2() {
      if (!_client.shard.ready) {
        return false;
      }

      return true;
    }

    if (match1() && match2()) {
      _client.ready = true;
      _client._startTime = DateTime.now();

      _client._http.send("GET", "/oauth2/applications/@me").then((response) {
        _client.app =
            ClientOAuth2Application._new(response.body as Map<String, dynamic>, _client);

        _client._events.onReady.add(ReadyEvent._new(_client));
        logger.info("Connected and ready!");
      });
    } else {
      //logger.severe("Cannot setup bot properly.");
      //exit(1);
    }
  }*/
