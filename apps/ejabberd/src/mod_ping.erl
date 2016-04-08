%%%----------------------------------------------------------------------
%%% File    : mod_ping.erl
%%% Author  : Brian Cully <bjc@kublai.com>
%%% Purpose : Support XEP-0199 XMPP Ping and periodic keepalives
%%% Created : 11 Jul 2009 by Brian Cully <bjc@kublai.com>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_ping).
-author('bjc@kublai.com').
%% 模块写的很精良
%% 也很通用，但是有以下几个问题
%% 1.服务器主动探测客户端
%% 2.由于pong包没有及时返回导致误判为离线，默认32s的超时间隔
-behavior(gen_mod).
-behavior(gen_server).
-xep([{xep, 199}, {version, "2.0"}]).
-include("ejabberd.hrl").
-include("jlib.hrl").

-define(SUPERVISOR, ejabberd_sup).
-define(DEFAULT_SEND_PINGS, false). % bool()
-define(DEFAULT_PING_INTERVAL, 60). % seconds
-define(DEFAULT_PING_REQ_TIMEOUT, 32).

-define(DICT, dict).

%% API
-export([start_link/2, start_ping/2, stop_ping/2]).

%% gen_mod callbacks
-export([start/2, stop/1]).

%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2,
         handle_info/2, code_change/3]).

%% Hook callbacks
-export([iq_ping/3,
         user_online/3,
         user_offline/4,
         user_send/3,
         user_keep_alive/1]).

-record(state, {host = <<"">>,
                send_pings = ?DEFAULT_SEND_PINGS,
                ping_interval = ?DEFAULT_PING_INTERVAL,
                timeout_action = none,
                ping_req_timeout = ?DEFAULT_PING_REQ_TIMEOUT,
                timers = ?DICT:new()}).

%%====================================================================
%% API
%%====================================================================
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start_ping(Host, JID) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    gen_server:cast(Proc, {start_ping, JID}).

stop_ping(Host, JID) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    gen_server:cast(Proc, {stop_ping, JID}).

%%====================================================================
%% gen_mod callbacks
%%====================================================================
start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    PingSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                transient, 2000, worker, [?MODULE]},
    supervisor:start_child(?SUPERVISOR, PingSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    Pid = erlang:whereis(Proc),
    gen_server:call(Proc, stop),
    wait_for_process_to_stop(Pid),
    supervisor:delete_child(?SUPERVISOR, Proc).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, Opts]) ->
    SendPings = gen_mod:get_opt(send_pings, Opts, ?DEFAULT_SEND_PINGS),
    PingInterval = gen_mod:get_opt(ping_interval, Opts, ?DEFAULT_PING_INTERVAL),
    PingReqTimeout = gen_mod:get_opt(ping_req_timeout, Opts, ?DEFAULT_PING_REQ_TIMEOUT),
    TimeoutAction = gen_mod:get_opt(timeout_action, Opts, none),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, no_queue),
    mod_disco:register_feature(Host, ?NS_PING),
    %% 注册Client到Server的ping处理
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PING,
                                  ?MODULE, iq_ping, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PING,
                                  ?MODULE, iq_ping, IQDisc),

    maybe_add_hooks_handlers(Host, SendPings),

    {ok, #state{host = Host,
                send_pings = SendPings,
                ping_interval = timer:seconds(PingInterval),
                timeout_action = TimeoutAction,
                ping_req_timeout = timer:seconds(PingReqTimeout),
                timers = ?DICT:new()}}.

maybe_add_hooks_handlers(Host, true) ->
    %% 当ejabberd_c2s使用ejabberd_sm:open_session的时候
    %% 会调用这个hook
    ejabberd_hooks:add(sm_register_connection_hook, Host,
                       ?MODULE, user_online, 100),
    %% 当ejabberd_c2s使用ejabberd_sm:close_session的时候
    %% 会调用这个hook
    ejabberd_hooks:add(sm_remove_connection_hook, Host,
                       ?MODULE, user_offline, 100),
    ejabberd_hooks:add(user_send_packet, Host,
                       ?MODULE, user_send, 100),
    ejabberd_hooks:add(user_sent_keep_alive, Host,
                       ?MODULE, user_keep_alive, 100);
maybe_add_hooks_handlers(_, _) ->
    ok.

terminate(_Reason, #state{host = Host}) ->
    ejabberd_hooks:delete(sm_remove_connection_hook, Host,
                          ?MODULE, user_offline, 100),
    ejabberd_hooks:delete(sm_register_connection_hook, Host,
                          ?MODULE, user_online, 100),
    ejabberd_hooks:delete(user_send_packet, Host,
                          ?MODULE, user_send, 100),
    ejabberd_hooks:delete(user_sent_keep_alive, Host,
                          ?MODULE, user_keep_alive, 100),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PING),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PING),
    mod_disco:unregister_feature(Host, ?NS_PING).

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast({start_ping, JID}, State) ->
    Timers = add_timer(JID, State#state.ping_interval, State#state.timers),
    {noreply, State#state{timers = Timers}};
handle_cast({stop_ping, JID}, State) ->
    Timers = del_timer(JID, State#state.timers),
    {noreply, State#state{timers = Timers}};
%% 收到心跳的timeout
%% 开始杀掉当前的session    
handle_cast({iq_pong, JID, timeout}, State) ->
    Timers = del_timer(JID, State#state.timers),
    ejabberd_hooks:run(user_ping_timeout, State#state.host, [JID]),
    %% 此处默认操作是没有操作
    %% 这样虽然浪费了一些资源，但是能保值不错误的踢下线
    case State#state.timeout_action of
        kill ->
            #jid{user = User, server = Server, resource = Resource} = JID,
            case ejabberd_sm:get_session_pid(User, Server, Resource) of
                Pid when is_pid(Pid) ->
                    ejabberd_c2s:stop(Pid);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    {noreply, State#state{timers = Timers}};
%% 如果没超时，发过来的信息是不同的
%% 我们可以直接忽略    
handle_cast(_Msg, State) ->
    {noreply, State}.
%% 主动向客户端发送一个ping消息
handle_info({timeout, _TRef, {ping, JID}},
            #state{ping_req_timeout = PingReqTimeout} = State) ->
    IQ = #iq{type = get,
             sub_el = [#xmlel{name = <<"ping">>,
                              attrs = [{<<"xmlns">>, ?NS_PING}]}]},
    Pid = self(),
    F = fun(Response) ->
                gen_server:cast(Pid, {iq_pong, JID, Response})
        end,
    From = jid:make(<<"">>, State#state.host, <<"">>),
    ejabberd_local:route_iq(From, JID, IQ, F, PingReqTimeout),
    Timers = add_timer(JID, State#state.ping_interval, State#state.timers),
    {noreply, State#state{timers = Timers}};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Hook callbacks
%%====================================================================
%% 处理client到server的ping
iq_ping(_From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    case {Type, SubEl} of
        {get, #xmlel{name = <<"ping">>}} ->
            IQ#iq{type = result, sub_el = []};
        _ ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_FEATURE_NOT_IMPLEMENTED]}
    end.
%% 用户上线的hook
user_online(_SID, JID, _Info) ->
    start_ping(JID#jid.lserver, JID).

user_offline(_SID, JID, _Info, _Reason) ->
    stop_ping(JID#jid.lserver, JID).
%% 每次用户发送数据的时候
%% 我们就需要重新启动timer，这个设计并不好呀
user_send(JID, _From, _Packet) ->
    start_ping(JID#jid.lserver, JID).
%% 用户保持在线的hook
user_keep_alive(JID) ->
    start_ping(JID#jid.lserver, JID).

%%====================================================================
%% Internal functions
%%====================================================================
%% 添加一个timer
%% 添加前，先检查是否存在
add_timer(JID, Interval, Timers) ->
    LJID = jid:to_lower(JID),
    %% 每次都重新生成一个Timer
    %% 并存储到Dict中
    NewTimers = case ?DICT:find(LJID, Timers) of
                    {ok, OldTRef} ->
                        cancel_timer(OldTRef),
                        ?DICT:erase(LJID, Timers);
                    _ ->
                        Timers
                end,
    TRef = erlang:start_timer(Interval, self(), {ping, JID}),
    ?DICT:store(LJID, TRef, NewTimers).

del_timer(JID, Timers) ->
    LJID = jid:to_lower(JID),
    case ?DICT:find(LJID, Timers) of
        {ok, TRef} ->
            cancel_timer(TRef),
            ?DICT:erase(LJID, Timers);
        _ ->
            Timers
    end.

cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive
                {timeout, TRef, _} ->
                    ok
            after 0 ->
                      ok
            end;
        _ ->
            ok
    end.

wait_for_process_to_stop(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} ->
            ok
    after
        1000 ->
            {error, still_running}
    end.

