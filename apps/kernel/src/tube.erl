-module(tube).
-export([open/1,open/2]).
-export([accept/2]).
-export([close/1]).

-define(STATE_INITIALISING,		"1").
-define(STATE_INIT_WAIT,		"2").
-define(STATE_INITIALISED,		"3").
-define(STATE_CONNECTED,		"4").
-define(STATE_CLOSING,			"5").
-define(STATE_CLOSED,			"6").

open(Domid) -> open(Domid, 0).
open(Domid, Tid) when is_integer(Domid), is_integer(Tid) ->
	Me = xenstore:domid(),
	NockDir = lc(["/local/domain/",Me,"/data/nock/",Domid,"/",Tid]),
	TipDir  = lc(["/local/domain/",Domid,"/data/tip/",Me,"/",Tid]),
	case xenstore:read(NockDir) of
		{ok,_} -> {error,exists};
		_      -> open1(NockDir, TipDir) end;
open(_, _) -> {error,badarg}.

open1(NockDir, TipDir) ->
	case xenstore:mkdir(TipDir) of
		ok ->
			ok = xenstore:mkdir(NockDir),
			ok = xenstore:write(lc(NockDir, "/tip"), TipDir),
			ok = xenstore:write(lc(NockDir, "/state"), ?STATE_INIT_WAIT),
			TipState = lc(TipDir, "/state"),
			Pid = spawn(fun() -> ok = xenstore:watch(TipState),
								 tloop(TipState, TipDir, NockDir) end),
			ok = xenstore:write(lc(TipDir, "/nock"), NockDir),
			{ok,Pid};
		{error,eacces} -> {error,not_found} end.

close(Pid) -> Pid ! {terminate,self()},
			  receive {Pid,terminated} -> ok end.

tloop(TipState, TipDir, NockDir) ->
	receive {watch,TipState} ->
				case xenstore:read(TipState) of
					{ok,S} ->
						tevent(S, TipDir, NockDir), tloop(TipState, TipDir, NockDir);
					{error,enoent} ->
						tloop(TipState, TipDir, NockDir);
					{error,eacces} -> tdone(TipState, NockDir) end;
			{terminate,From} ->
				tdone(TipState, NockDir),
				From ! {self(),terminated} end.

tdone(TipState, NockDir) ->
	ok = xenstore:unwatch(TipState),
	ok = xenstore:delete(lc(NockDir, "/state")),
	ok = xenstore:delete(NockDir).

tevent(?STATE_INITIALISING, _, _) -> ok;

tevent(?STATE_INITIALISED, TipDir, NockDir) ->
	{ok,TxRingRef} = xenstore:read(lc(TipDir, "/tx-ring-ref")),
	{ok,RxRingRef} = xenstore:read(lc(TipDir, "/rx-ring-ref")),
	{ok,EventChannel} = xenstore:read(lc(TipDir, "/event-channel")),

	%%TODO
	io:format("START tube port: ~s/~s/~s\n", [TxRingRef,RxRingRef,EventChannel]),

	ok = xenstore:write(lc(NockDir, "/state"), ?STATE_CONNECTED);

tevent(?STATE_CONNECTED, _, _) -> ok.

accept(NockDir, TipDir) ->
	NockState = lc(NockDir, "/state"),
	Pid = spawn(fun() -> ok = xenstore:watch(NockState),
						 aloop(NockState, TipDir),
						 ok = xenstore:delete(TipDir),
						 ok = xenstore:unwatch(NockState) end),
	ok = xenstore:write(lc(TipDir, "/state"), ?STATE_INITIALISING),
	{ok,Pid}.

aloop(NockState, TipDir) ->
	receive {watch,NockState} ->
				case xenstore:read(NockState) of
					{ok,S} ->
						aevent(S, TipDir),
						aloop(NockState, TipDir);
					{error,_} -> done end end.

aevent(?STATE_INIT_WAIT, TipDir) ->

	%%TODO
	io:format("START tube port\n", []),
	TxRingRef = "1",
	RxRingRef = "2",
	EventChannel = "3",

	{ok,Tid} = xenstore:transaction(),
	ok = xenstore:write(lc(TipDir, "/tx-ring-ref"), TxRingRef, Tid),
	ok = xenstore:write(lc(TipDir, "/rx-ring-ref"), RxRingRef, Tid),
	ok = xenstore:write(lc(TipDir, "/event-channel"), EventChannel, Tid),
	ok = xenstore:write(lc(TipDir, "/state"), ?STATE_INITIALISED, Tid),
	ok = xenstore:commit(Tid);

aevent(?STATE_CONNECTED, TipDir) ->
	ok = xenstore:write(lc(TipDir, "/state"), ?STATE_CONNECTED).

%%state(?STATE_INITIALISING) -> "Initialising";
%%state(?STATE_INIT_WAIT)	   -> "InitWait";
%%state(?STATE_INITIALISED)  -> "Initialised";
%%state(?STATE_CONNECTED)	   -> "Connected";
%%state(?STATE_CLOSING)	   -> "Closing";
%%state(?STATE_CLOSED)	   -> "Closed".

lc(X)    -> lists:concat(X).
lc(X, Y) -> lists:concat([X,Y]).
