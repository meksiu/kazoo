%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2014, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(omnipresence_shared_listener).

-behaviour(gen_listener).

-export([start_link/0]).
-export([start_listener/0]).

-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("omnipresence.hrl").
-include_lib("whistle_apps/include/wh_hooks.hrl").

-record(state, {subs_pid :: pid()
                ,subs_ref :: reference()
               }).

-define(BINDINGS, [{'self', []}
                   %% channel events that toggle presence lights
                   ,{'call', [{'restrict_to', ['CHANNEL_CREATE'
                                               ,'CHANNEL_ANSWER'
                                               ,'CHANNEL_DESTROY'
                                               ,'CHANNEL_CONNECTED'
                                               ,'CHANNEL_DISCONNECTED'
                                              ]}
                              ,'federate'
                             ]}
                   ,{'presence', [{'restrict_to', ['update'
                                                   ,'mwi_update'
                                                   ,'reset'
                                                  ]}
                                  ,'federate'
                                 ]}
                   ,{'omnipresence', [{'restrict_to', ['subscribe']}]}
                  ]).
-define(RESPONDERS, [{{'omnip_subscriptions', 'handle_channel_event'}
                      ,[{<<"call_event">>, <<"*">>}]
                     }
                     ,{{'omnip_subscriptions', 'handle_presence_update'}
                       ,[{<<"presence">>, <<"update">>}]
                      }
                     ,{{'omnip_subscriptions', 'handle_mwi_update'}
                       ,[{<<"presence">>, <<"mwi_update">>}]
                      }
                     ,{{'omnip_subscriptions', 'handle_reset'}
                       ,[{<<"presence">>, <<"reset">>}]
                      }
                     ,{{'omnip_subscriptions', 'handle_kamailio_subscribe'}
                       ,[{<<"presence">>, <<"subscription">>}]
                      }
                    ]).
-define(QUEUE_NAME, <<"omnip_shared_listener">>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).

-define(LISTENER_PARAMS, [{'bindings', ?BINDINGS}
                              ,{'responders', ?RESPONDERS}
                              ,{'queue_name', ?QUEUE_NAME}
                              ,{'queue_options', ?QUEUE_OPTIONS}
                              ,{'consume_options', ?CONSUME_OPTIONS}
                             ]).

%%%===================================================================
%%% API
%%%===================================================================
-spec start_listener() -> 'ok'.
start_listener() ->
    gen_listener:cast(?MODULE, {'ready'}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_listener:start_link({'local', ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    put('callid', ?MODULE),
    gen_listener:cast(self(), 'find_subscriptions_srv'),
    lager:debug("omnipresence_listener started"),
    {'ok', #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast('find_subscriptions_srv', #state{subs_pid=_Pid}=State) ->
    case omnipresence_sup:subscriptions_srv() of
        'undefined' ->
            lager:debug("no subs_pid"),
            gen_listener:cast(self(), 'find_subscriptions_srv'),
            timer:sleep(500),
            {'noreply', State#state{subs_pid='undefined'}};
        P when is_pid(P) ->
            lager:debug("new subs pid: ~p", [P]),
            {'noreply', State#state{subs_pid=P
                                    ,subs_ref=erlang:monitor('process', P)
                                   }}
    end;
handle_cast({'gen_listener',{'created_queue',_Queue}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};
handle_cast({'ready'}, State) ->
    gen_listener:start_listener(self(), ?LISTENER_PARAMS),
    {'noreply', State};
handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, 'process', Pid, _R}, #state{subs_pid=Pid
                                                      ,subs_ref=Ref
                                                     }=State) ->
    gen_listener:cast(self(), 'find_subscriptions_srv'),
    {'noreply', State#state{subs_pid='undefined'
                            ,subs_ref='undefined'
                           }};
handle_info(?HOOK_EVT(_, EventName, JObj), State) ->
    _ = wh_util:spawn('omnip_subscriptions', 'handle_channel_event', [EventName, JObj]),
    {'noreply', State};
handle_info(_Info, State) ->
    lager:debug("unhandled msg: ~p", [_Info]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, #state{subs_pid=S}) ->
    {'reply', [{'omnip_subscriptions', S}]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
