-module(zone_fsm).
-behaviour(gen_fsm).

-include("include/records.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/1]).

-export([handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([init/1,
         locked/2,
         valid/2,
         walking/2]).

-export([show_actors/1,
         say/2]).

-define(WALKSPEED, 150).


start_link(TCP) ->
    gen_fsm:start_link(?MODULE, TCP, []).

init(TCP) ->
    {ok, locked, #zone_state{tcp = TCP}}.

locked({connect, AccountID, CharacterID, SessionIDa, _Gender}, State) ->
    {char, CharNode} = config:get_env(zone, server.char),
    Session = gen_server_tcp:call({server, CharNode},
                                  {verify_session, AccountID, CharacterID, SessionIDa}),

    case Session of
        {ok, FSM} ->
            {ok, C} = gen_fsm:sync_send_event(FSM, switch_zone),

            log:debug("Switched to Zone server.",
                      [{char_state, C}]),

            {ok, Map, MapServer} = gen_server_tcp:call(State#zone_state.server,
                                                       {add_player,
                                                        (C#char_state.char)#char.map,
                                                        {(C#char_state.account)#account.id, self()}}),

            State#zone_state.tcp ! {parse, zone_packets:new(C#char_state.packet_ver)},

            State#zone_state.tcp ! {account_id, AccountID},
            State#zone_state.tcp ! {accept, {zone_master:tick(),
                                             {(C#char_state.char)#char.x,
                                              (C#char_state.char)#char.y, 0}}},

            ?MODULE:say("Welcome to Aliter.", State),

            {next_state, valid, State#zone_state{map = Map,
                                                 map_server = MapServer,
                                                 account = C#char_state.account,
                                                 char = C#char_state.char,
                                                 id_a = C#char_state.id_a,
                                                 id_b = C#char_state.id_b,
                                                 packet_ver = C#char_state.packet_ver}};
        invalid ->
            log:warning("Invalid zone login attempt caught.",
                        [{account_id, AccountID},
                         {character_id, CharacterID}]),
            {next_state, locked, State}
    end;
locked(Event, State) ->
    ?MODULE:handle_event(Event, locked, State).

valid(quit, State = #zone_state{account = #account{id = AccountID}}) ->
    log:info("Player quitting.",
             [{account, AccountID}]),

    State#zone_state.tcp ! {quit_response, 0},

    {next_state, valid, State};
valid({request_name, ActorID}, State = #zone_state{account = #account{id = AccountID},
                                                   char = #char{name = CharacterName}}) ->
    log:debug("Sending actor name.", [{actor, ActorID}]),

    Name = if
               ActorID == AccountID ->
                   {actor_name_full,
                    {ActorID,
                     CharacterName,
                     "Party Name",
                     "Guild Name",
                     "Tester"}};
               true ->
                   case gen_server:call(State#zone_state.map_server,
                                        {get_actor, ActorID}) of
                       {player, FSM} ->
                           {ok, Z} = gen_fsm:sync_send_all_state_event(FSM, get_state),
                           {actor_name_full,
                            {ActorID,
                             (Z#zone_state.char)#char.name,
                             "Other Party Name",
                             "Other Guild Name",
                             "Other Tester"}};
                       {npc, NPC} ->
                           {actor_name, {ActorID, NPC#npc.name}};
                       none ->
                           "Unknown"
                   end
           end,

    State#zone_state.tcp ! Name,

    {next_state, valid, State};
valid({char_select, Type}, State) ->
    log:debug("User requesting to go back to char screen.", [{type, Type}]),
    State#zone_state.tcp ! {confirm_back_to_char, {1}},
    {next_state, valid, State};

valid({npc_activate, ActorID}, State = #zone_state{map_server = MapServer}) ->
    log:warning("Activating NPC.",
                [{id, ActorID}]),

    case gen_server:call(MapServer, {get_actor, ActorID}) of
        {npc, NPC} ->
            log:warning("NPC found.",
                        [{id, ActorID}]),

            Mod = (NPC#npc.main):new(self()),
            log:debug("NPC initialized.",
                      [{result, Mod}]),

            Pid = spawn(fun() -> Mod:main() end),

            {next_state, valid, State#zone_state{npc = {Pid, NPC}}};
        _Invalid ->
            log:error("NPC not found.",
                        [{id, ActorID}]),

            {next_state, valid, State}
    end;
valid({npc_menu_select, _ActorID, Selection},
      State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! Selection,
    {next_state, valid, State};
valid({npc_next, _ActorID}, State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! continue,
    {next_state, valid, State};
valid({npc_close, _ActorID}, State = #zone_state{npc = {Pid, _NPC}}) ->
    Pid ! close,
    {next_state, valid, State};
valid(map_loaded, State) ->
    show_actors(State),

    {next_state, valid, State};
valid(request_guild_status,
      State = #zone_state{char = #char{id = CharacterID,
                                       guild_id = GuildID}}) ->
    log:debug("Requested guild status."),

    if
        GuildID /= 0 ->
            GetGuild = fun() ->
                               mnesia:read(guild, GuildID)
                       end,
            case mnesia:transaction(GetGuild) of
                {atomic, [#guild{master_id = CharacterID}]} ->
                    State#zone_state.tcp ! {guild_status, master};
                _Error ->
                    State#zone_state.tcp ! {guild_status, member}
            end;
        true ->
            State#zone_state.tcp ! {guild_status, none}
    end,

    {next_state, valid, State};
valid({request_guild_info, 0},
      State = #zone_state{char = #char{guild_id = GuildID}}) when GuildID /= 0 ->
    log:debug("Requested first page of guild info."),

    GetGuild = fun() -> mnesia:read(guild, GuildID) end,
    case mnesia:transaction(GetGuild) of
        {atomic, [G]} ->
            State#zone_state.tcp ! {guild_info, G},
            State#zone_state.tcp ! {guild_relationships, G#guild.relationships};
        _Other ->
            ok
    end,

    {next_state, valid, State};
valid({request_guild_info, 1},
      State = #zone_state{char = #char{guild_id = GuildID}}) when GuildID /= 0 ->
    log:debug("Requested second page of guild info."),

    {char, CharNode} = config:get_env(zone, server.char),

    GetMembers = gen_server_tcp:call({server, CharNode},
                                     {get_chars,
                                      fun() ->
                                          qle:e(qlc:q([C || C <- mnesia:table(char),
                                                            C#char.guild_id == GuildID]))
                                      end}),
    case GetMembers of
        {atomic, Members} ->
            State#zone_state.tcp ! {guild_members, Members};
        _Error ->
            ok
    end,

    {next_state, valid, State};
valid({request_guild_info, 2}, State) ->
    log:debug("Requested third page of guild info."),
    {next_state, valid, State};
valid({walk, {ToX, ToY, ToD}},
      State = #zone_state{tcp = TCP,
                          map = Map,
                          map_server = MapServer,
                          account = #account{id = AccountID},
                          char = C = #char{id = CharacterID,
                                           x = X,
                                           y = Y}}) ->

    log:debug("Received walk request.",
              [{coords, {ToX, ToY, ToD}}]),

    {Time, PathFound} = timer:tc(nif, pathfind, [Map#map.id, [X | Y], [ToX | ToY]]),

    log:error("Path found.",
              [{map_size, {bit_size(Map#map.cells), byte_size(Map#map.cells)}},
               {path, PathFound},
               {elapsed, Time}]),

    case PathFound of
        [{SX, SY, SDir} | Path] ->
            {ok, Timer} = walk_interval(SDir),
            {FX, FY, _FDir} = lists:last(PathFound),

            gen_server:cast(MapServer,
                            {send_to_other_players_in_sight,
                             {X, Y},
                             CharacterID,
                             actor_move,
                             {AccountID, {X, Y}, {FX, FY}, zone_master:tick()}}),

            TCP ! {move, {{X, Y}, {FX, FY}, zone_master:tick()}},

            {next_state, walking, State#zone_state{char = C#char{x = SX, y = SY},
                                                   walk_timer = Timer,
                                                   walk_prev = {now(), SDir},
                                                   walk_path = Path}};
        _Error ->
            {next_state, valid, State}
    end;
valid({change_direction, Head, Body},
      State = #zone_state{map_server = MapServer,
                          account = #account{id = AccountID},
                          char = #char{id = CharacterID,
                                       x = X,
                                       y = Y}}) ->
    gen_server:cast(MapServer,
                    {send_to_other_players_in_sight,
                     {X, Y},
                     CharacterID,
                     change_direction,
                     {AccountID, Head, Body}}),

    {next_state, valid, State};
valid(Event, State) ->
    ?MODULE:handle_event(Event, valid, State).

walking({walk, {ToX, ToY, ToD}},
        State = #zone_state{map = Map,
                            char = #char{x = X,
                                         y = Y}}) ->
    log:error("Walk request while walking.",
              [{coords, {ToX, ToY, ToD}},
               {current_position, {X, Y}}]),

    {Time, Path} = timer:tc(nif, pathfind, [Map#map.id, [X | Y], [ToX | ToY]]),

    log:error("Path found.",
              [{map_size, {bit_size(Map#map.cells), byte_size(Map#map.cells)}},
               {path, Path},
               {elapsed, Time}]),

    {next_state, walking, State#zone_state{walk_path = Path,
                                           walk_changed = {X, Y}}};
walking(step, State = #zone_state{char = C,
                                  account = A,
                                  tcp = TCP,
                                  map_server = MapServer,
                                  walk_timer = Timer,
                                  walk_prev = {Time, PDir},
                                  walk_path = Path,
                                  walk_changed = Changed}) ->
    case Path of
        [] ->
            timer:cancel(Timer),
            log:error("Done walking."),
            {next_state, valid, State#zone_state{walk_timer = undefined,
                                                 walk_path = undefined,
                                                 walk_changed = false}};
        [{CX, CY, CDir} | Rest] ->
            if
                CDir == PDir ->
                    NewTimer = Timer;
                true ->
                    timer:cancel(Timer),

                    {ok, NewTimer} = walk_interval(CDir)
            end,

            case Changed of
                {X, Y} ->
                    {FX, FY, _FDir} = lists:last(Path),

                    gen_server:cast(MapServer,
                                    {send_to_other_players_in_sight,
                                     {X, Y},
                                     C#char.id,
                                     actor_move,
                                     {A#account.id, {X, Y}, {FX, FY}, zone_master:tick()}}),

                    TCP ! {move, {{X, Y}, {FX, FY}, zone_master:tick()}};
                _ -> ok
            end,

            log:warning("Stepping.", [{direction, CDir},
                                      {elapsed, trunc(timer:now_diff(now(), Time) / 1000)},
                                      {current_pos, {CX, CY}}]),

            {next_state, walking, State#zone_state{char = C#char{x = CX, y = CY},
                                                   walk_timer = NewTimer,
                                                   walk_prev = {Time, CDir},
                                                   walk_path = Rest,
                                                   walk_changed = false}}
    end;
walking(Event, State) ->
    ?MODULE:handle_event(Event, walking, State).

handle_event({speak, Message},
             StateName,
             StateData = #zone_state{tcp = TCP,
                                     map_server = MapServer,
                                     account = #account{id = AccountID},
                                     char = #char{id = CharacterID,
                                                  x = X,
                                                  y = Y}}) ->
    [Name | Rest] = re:split(Message, " : ", [{return, list}]),
    Said = lists:concat(Rest),

    log:debug("Speaking.",
              [{message, Message},
               {name, Name},
               {rest, Rest},
               {first, hd(Said)}]),

    if
        hd(Said) == 92 -> % GM command
            [Command | Args] = zone_commands:parse(tl(Said)),
            FSM = self(),
            spawn(fun() -> zone_commands:execute(FSM, Command, Args, StateData) end);
        true ->
            gen_server:cast(MapServer,
                            {send_to_other_players_in_sight,
                             {X, Y},
                             CharacterID,
                             actor_message,
                             {AccountID, Message}}),

            TCP ! {message, Message}
    end,

    {next_state, StateName, StateData};
handle_event({broadcast, Message}, StateName, StateData) ->
    gen_server:cast(zone_master,
                    {send_to_all,
                     {send_to_all,
                      {send_to_players,
                       broadcast,
                       Message}}}),

    {next_state, StateName, StateData};
handle_event(stop, _StateName, StateData) ->
    log:info("Zone FSM stopping."),
    {stop, normal, StateData};
handle_event({tick, Tick}, StateName, StateData) when StateName /= locked ->
    log:debug("Got tick; syncing.", [{tick, Tick}]),
    StateData#zone_state.tcp ! {tick, zone_master:tick()},
    {next_state, StateName, StateData};
handle_event({set_server, Server}, StateName, StateData) ->
    {next_state, StateName, StateData#zone_state{server = Server}};
handle_event({send_packet, Packet, Data}, StateName, StateData) ->
    StateData#zone_state.tcp ! {Packet, Data},
    {next_state, StateName, StateData};
handle_event({send_packet_if, Pred, Packet, Data}, StateName, StateData) ->
    case Pred(StateData) of
        true ->
            StateData#zone_state.tcp ! {Packet, Data};
        false ->
            ok
    end,

    {next_state, StateName, StateData};
handle_event({show_to, FSM}, StateName, StateData = #zone_state{account = A,
                                                                char = C}) ->
    gen_fsm:send_all_state_event(FSM,
                                 {send_packet,
                                  change_look,
                                  C}),

    gen_fsm:send_all_state_event(FSM,
                                 {send_packet,
                                  actor,
                                  {normal, A, C}}),

    {next_state, StateName, StateData};
handle_event({get_state, From}, StateName, StateData) ->
    From ! {ok, StateData},
    {next_state, StateName, StateData};
handle_event({update_state, Fun}, StateName, StateData) ->
    {next_state, StateName, Fun(StateData)};
handle_event(Event, StateName, StateData) ->
    log:debug("Zone FSM received event.", [{event, Event}, {state, StateName}]),
    {next_state, StateName, StateData}.

handle_sync_event(get_state, _From, StateName, StateData) ->
    log:debug("Handling get_state handle_sync_event."),
    {reply, {ok, StateData}, StateName, StateData};
handle_sync_event(_Event, _From, StateName, StateData) ->
    log:debug("Zone FSM got sync event."),
    {next_state, StateName, StateData}.

handle_info({'EXIT', _From, Reason}, _StateName, StateData) ->
    log:debug("Zone FSM got EXIT signal.", [{reason, Reason}]),
    {stop, normal, StateData};
handle_info(Info, StateName, StateData) ->
    log:debug("Zone FSM got info.", [{info, Info}]),
    {next_state, StateName, StateData}.

terminate(_Reason, _StateName, #zone_state{map_server = MapServer,
                                           account = #account{id = AccountID},
                                           char = Character}) ->
    log:info("Zone FSM terminating.",
            [{account, AccountID}]),

    gen_server:cast(MapServer,
                    {send_to_other_players,
                     Character#char.id,
                     vanish,
                     {AccountID, 3}}),

    {char, CharNode} = config:get_env(zone, server.char),

    gen_server_tcp:cast({server, CharNode},
                        {save_char, Character}),

    gen_server_tcp:cast(MapServer, {remove_player, AccountID});
terminate(_Reason, _StateName, _StateData) ->
    log:debug("Zone FSM terminating."),
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


% Helper walking function
walk_interval(N) ->
    Interval = case N band 1 of
                   1 ->
                       log:debug("Walking diagonally."),
                       trunc(?WALKSPEED * 1.4);
                   0 ->
                       log:debug("Walking straight."),
                       ?WALKSPEED
               end,

    timer:apply_interval(Interval,
                         gen_fsm,
                         send_event,
                         [self(), step]).


show_actors(#zone_state{map_server = MapServer,
                        char = C,
                        account = A}) ->
    gen_server:cast(MapServer,
                    {send_to_other_players,
                     C#char.id,
                     change_look,
                     C}),

    gen_server:cast(MapServer,
                    {send_to_other_players,
                     C#char.id,
                     actor,
                     {new, A, C}}),

    gen_server:cast(MapServer,
                    {show_actors,
                     {A#account.id, self()}}).

say(Message, State) ->
    State#zone_state.tcp ! {message, Message}.

