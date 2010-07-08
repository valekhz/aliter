-module(char_packets_24).

-include("include/records.hrl").

-export([unpack/1, pack/2]).

-define(WALKSPEED, 150).


unpack(<<16#65:16/little,
         AccountID:32/little,
         LoginIDa:32/little,
         LoginIDb:32/little,
         _:16,
         Gender:8>>) ->
    {connect,
     AccountID,
     LoginIDa,
     LoginIDb,
     Gender};
unpack(<<16#66:16/little,
         Num:8/little>>) ->
    {choose,
     Num};
unpack(<<16#67:16/little,
         Name:24/little-binary-unit:8,
         Str:8,
         Agi:8,
         Vit:8,
         Int:8,
         Dex:8,
         Luk:8,
         Num:8,
         HairColor:16/little,
         HairStyle:16/little>>) ->
    {create, string:strip(binary_to_list(Name), both, 0), Str, Agi, Vit, Int, Dex, Luk, Num, HairColor, HairStyle};
unpack(<<16#68:16/little,
         CharacterID:32/little,
         EMail:40/little-binary-unit:8>>) ->
    {delete, CharacterID, string:strip(binary_to_list(EMail), both, 0)};
unpack(<<16#187:16/little,
         AccountID:32/little>>) ->
    {keepalive, AccountID};
unpack(<<16#28d:16/little,
         AccountID:32/little,
         CharacterID:32/little,
         NewName:24/little-binary-unit:8>>) ->
    {check_name, AccountID, CharacterID, string:strip(binary_to_list(NewName), both, 0)};
unpack(<<16#28f:16/little, CharacterID:32/little>>) ->
    {rename, CharacterID};
unpack(Unknown) ->
    log:warning("Got unknown data.", [{data, Unknown}]),
    false.

pack(characters, {Characters, MaxSlots, AvailableSlots, PremiumSlots}) ->
    [<<16#6b:16/little,
       (length(Characters) * 112 + 27):16/little,
       MaxSlots:8/little,
       AvailableSlots:8/little,
       PremiumSlots:8/little>>,
     list_to_binary(lists:duplicate(20, 0))] ++
    lists:map(fun(C) -> character(C) end, Characters);
pack(refuse, Reason) ->
    <<16#6c:16/little,
      Reason:8/little>>;
pack(character_created, Character) ->
    [<<16#6d:16/little>>,
     character(Character)];
pack(creation_failed, Reason) ->
    <<16#6e:16/little,
      Reason:16/little>>;
pack(character_deleted, ok) ->
    <<16#6f:16/little>>;
pack(deletion_failed, Reason) ->
    <<16#70:16/little,
      Reason:16/little>>;
pack(zone_connect, {#char{id = ID, map = Map}, {ZA, ZB, ZC, ZD}, ZonePort}) ->
    [<<16#71:16/little,
       ID:32/little>>,
     list_to_binary(string:left(Map ++ ".gat", 16, 0)),
     <<ZA, ZB, ZC, ZD, ZonePort:16/little>>];
pack(name_check_result, Result) ->
    <<16#28e:16/little,
      Result:16/little>>;
pack(rename_result, Result) ->
    <<16#290:16/little, Result:16/little>>;
pack(Header, Data) ->
    log:error("Cannot pack unknown data.",
               [{header, Header},
                {data, Data}]),
    <<>>.


character(C) ->
    [<<(C#char.id):32/little,
       (C#char.base_exp):32/little,
       (C#char.zeny):32/little,
       (C#char.job_exp):32/little,
       (C#char.job_level):32/little,
       0:32/little, % TODO: ?
       0:32/little, % TODO: ?
       (C#char.effects):32/little,
       (C#char.karma):32/little,
       (C#char.manner):32/little,
       (C#char.status_points):16/little,
       (C#char.hp):32/little,
       (C#char.max_hp):32/little,
       (C#char.sp):16/little,
       (C#char.max_sp):16/little,
       ?WALKSPEED:16/little, % TODO (Walk speed)
       (C#char.job):16/little,
       (C#char.hair_style):16/little,
       (C#char.view_weapon):16/little,
       (C#char.base_level):16/little,
       (C#char.skill_points):16/little,
       (C#char.view_head_bottom):16/little,
       (C#char.view_shield):16/little,
       (C#char.view_head_top):16/little,
       (C#char.view_head_middle):16/little,
       (C#char.hair_colour):16/little,
       (C#char.clothes_colour):16/little>>,
     list_to_binary(string:left(C#char.name, 24, 0)),
     <<(C#char.str):8,
       (C#char.agi):8,
       (C#char.vit):8,
       (C#char.int):8,
       (C#char.dex):8,
       (C#char.luk):8,
       (C#char.num):16/little,
       (C#char.renamed):16/little>>].
