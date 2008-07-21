%%---------------------------------------------------------------------------
%% @author Tony Garnock-Jones <tonyg@lshift.net>
%% @author Rabbit Technologies Ltd. <info@rabbitmq.com>
%% @copyright 2008 Tony Garnock-Jones and Rabbit Technologies Ltd.
%% @license
%%
%% This program is dual licensed under the terms of the Mozilla Public
%% License and the GNU General Public License. Please see the
%% license-specific blocks below for details.
%%
%%---------------------------------------------------------------------------
%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial Technologies
%%   LLC., and Rabbit Technologies Ltd. are Copyright (C) 2007-2008
%%   LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
%%---------------------------------------------------------------------------
%%
%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License as
%% published by the Free Software Foundation; either version 2 of the
%% License, or (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%% General Public License for more details.
%%                         
%% You should have received a copy of the GNU General Public License
%% along with this program; if not, write to the Free Software
%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%% 02111-1307 USA
%%---------------------------------------------------------------------------
%%
%% @doc RabbitMQ Rabbiter bot.
%%
%% All of the exposed functions of this module are private to the
%% implementation. See the <a
%% href="overview-summary.html">overview</a> page for more
%% information.

-module(mod_rabbiter).

-behaviour(gen_server).
-behaviour(gen_mod).

-export([start_link/2, start/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([route/3]).
-export([consumer_init/4, consumer_main/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include_lib("rabbitmq_server/include/rabbit.hrl").
-include_lib("rabbitmq_server/include/rabbit_framing.hrl").

-define(VHOST, <<"/">>).
-define(REALM, #resource{virtual_host = ?VHOST, kind = realm, name = <<"/data">>}).
-define(XNAME(Name), #resource{virtual_host = ?VHOST, kind = exchange, name = Name}).
-define(QNAME(Name), #resource{virtual_host = ?VHOST, kind = queue, name = Name}).

-define(IDEBUG(F,A), ?INFO_MSG(F,A)).

-record(state, {host}).
-record(rabbiter_consumer_process, {queue, pid}).
-record(rabbiter_user_info, {jid, account_status}).
-record(consumer_state, {lserver, consumer_tag, queue, priorities}).

-define(PROCNAME, ejabberd_mod_rabbiter).

-define(BOTNAME, "rabbiter").
-define(RABBITER_MIME_TYPE, "application/x-rabbiter").

%% @hidden
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    mnesia:create_table(rabbiter_consumer_process,
			[{attributes, record_info(fields, rabbiter_consumer_process)}]),
    mnesia:create_table(rabbiter_user_info,
			[{attributes, record_info(fields, rabbiter_user_info)},
			 {disc_copies, [node()]}]),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

%% @hidden
start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc,
		 {?MODULE, start_link, [Host, Opts]},
		 temporary,
		 1000,
		 worker,
		 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

%% @hidden
stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

%%---------------------------------------------------------------------------

%% @hidden
init([Host, Opts]) ->
    case catch rabbit_mnesia:create_tables() of
	{error, {table_creation_failed, _, _, {already_exists, _}}} ->
	    ok;
	ok ->
	    ok
    end,
    ok = rabbit:start(),

    MyHost = gen_mod:get_opt_host(Host, Opts, "rabbiter.@HOST@"),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),

    probe_queues(MyHost),

    {ok, #state{host = MyHost}}.

%% @hidden
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%% @hidden
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @hidden
handle_info({route, From, To, Packet}, State) ->
    safe_route(non_shortcut, From, To, Packet),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @hidden
terminate(_Reason, State) ->
    ejabberd_router:unregister_route(State#state.host),
    ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%---------------------------------------------------------------------------

%% @hidden
route(From, To, Packet) ->
    safe_route(shortcut, From, To, Packet).

safe_route(ShortcutKind, From, To, Packet) ->
    ?IDEBUG("~p~n~p ->~n~p~n~p", [ShortcutKind, From, To, Packet]),
    case catch do_route(From, To, Packet) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p~nwhen processing: ~p",
		       [Reason, {From, To, Packet}]);
	_ ->
	    ok
    end.

do_route(#jid{lserver = FromServer} = From,
	 #jid{lserver = ToServer} = To,
	 {xmlelement, "presence", _, _})
  when FromServer == ToServer ->
    %% Break tight loops by ignoring these presence packets.
    ?WARNING_MSG("Tight presence loop between~n~p and~n~p~nbroken.",
		 [From, To]),
    ok;
do_route(From, #jid{luser = ?BOTNAME} = To, {xmlelement, "presence", _, _} = Packet) ->
    Urn = jid_to_urn(From),
    case xml:get_tag_attr_s("type", Packet) of
	"subscribe" ->
	    send_presence(To, From, "subscribe");
	"subscribed" ->
	    ok = sub(To, From, Urn),
	    send_presence(To, From, "subscribed"),
	    send_presence(To, From, "");
	"unsubscribe" ->
	    ok = unsub(To, From, Urn),
	    send_presence(To, From, "unsubscribed"),
	    send_presence(To, From, "unsubscribe");
	"unsubscribed" ->
	    ok = unsub(To, From, Urn),
	    send_presence(To, From, "unsubscribed");

	"" ->
	    send_presence(To, From, ""),
	    start_consumer(Urn, From, To#jid.lserver, extract_priority(Packet));
	"unavailable" ->
	    stop_consumer(Urn, From);

	"probe" ->
	    send_presence(To, From, "");

	_Other ->
	    ?INFO_MSG("Other kind of presence~n~p", [Packet])
    end,
    ok;
do_route(From, #jid{luser = ?BOTNAME} = To, {xmlelement, "message", _, _} = Packet) ->
    case xml:get_subtag_cdata(Packet, "body") of
	"" ->
	    ?IDEBUG("Ignoring message with empty body", []);
	Body0 ->
	    Body = strip_bom(Body0),
	    case xml:get_tag_attr_s("type", Packet) of
		"error" ->
		    ?ERROR_MSG("Received error message~n~p -> ~p~n~p", [From, To, Packet]);
		_ ->
		    send_command_reply(To, From, do_command(To, From, Body, parse_command(Body)))
	    end
    end,
    ok;
do_route(_From, _To, _Packet) ->
    ?INFO_MSG("**** DROPPED~n~p~n~p~n~p", [_From, _To, _Packet]),
    ok.

strip_bom([239,187,191|C]) -> C;
strip_bom(C) -> C.

extract_priority(Packet) ->
    case xml:get_subtag_cdata(Packet, "priority") of
	"" ->
	    0;
	S ->
	    list_to_integer(S)
    end.

jid_to_urn(#jid{luser = U, lserver = S}) ->
    list_to_binary("urn:rabbit.com:rabbiter:" ++ U ++ "@" ++ S).

urn_to_jid(<<"urn:rabbit.com:rabbiter:", JidText/binary>>) ->
    case jlib:string_to_jid(binary_to_list(JidText)) of
	error -> {error, invalid_format};
	JID -> {ok, JID}
    end;
urn_to_jid(_) ->
    {error, invalid_format}.

urn_to_string(<<"urn:rabbit.com:rabbiter:", JidText/binary>>) ->
    binary_to_list(JidText);
urn_to_string(Urn) ->
    binary_to_list(Urn).

string_to_urn(JidStr) ->
    list_to_binary(["urn:rabbit.com:rabbiter:", JidStr]).

sub(BotJid, JID, Urn) ->
    StrippedJid = jlib:jid_remove_resource(JID),
    ?IDEBUG("Subscribing~n~p~n~p", [StrippedJid, Urn]),
    rabbit_exchange:declare(?REALM, Urn, fanout, true, false, []),
    rabbit_amqqueue:declare(?REALM, Urn, true, false, []),
    %% rabbit_amqqueue:add_binding(?QNAME(Urn), ?XNAME(Urn), <<>>, []), %% self-following
    update_user_info(StrippedJid,
		     fun (UserInfo) -> welcome_user(BotJid, JID, UserInfo) end),
    ok.

unsub(_BotJid, JID, Urn) ->
    StrippedJid = jlib:jid_remove_resource(JID),
    ?IDEBUG("Unsubscribing~n~p~n~p", [StrippedJid, Urn]),
    stop_consumer(Urn, all),
    case rabbit_amqqueue:lookup(?QNAME(Urn)) of
	{ok, Q} -> rabbit_amqqueue:delete(Q, false, false);
	{error, not_found} -> ok
    end,
    rabbit_exchange:delete(?XNAME(Urn), false),
    update_user_info(StrippedJid,
		     fun (UserInfo) -> UserInfo#rabbiter_user_info{account_status = deleted} end),
    ok.

update_user_info(UserJid, F) ->
    mnesia:transaction(
      fun () ->
	      UserInfo = case mnesia:wread({rabbiter_user_info, UserJid}) of
			     [UI] -> UI;
			     [] -> #rabbiter_user_info{jid = UserJid, account_status = new}
			 end,
	      mnesia:write(F(UserInfo))
      end),
    ok.

welcome_user(BotJid, JID, #rabbiter_user_info{account_status = AccountStatus} = UserInfo) ->
    case AccountStatus of
	new ->
	    ?IDEBUG("Welcoming new subscriber~n~p", [JID]),
	    send_chat(BotJid, JID, newuser_welcome_message(JID));
	deleted ->
	    ?IDEBUG("Welcoming previously deleted subscriber~n~p", [JID]),
	    send_chat(BotJid, JID, olduser_welcome_message(JID));
	active ->
	    ?IDEBUG("Not welcoming active subscriber~n~p", [JID]),
	    ok
    end,
    UserInfo#rabbiter_user_info{account_status = active}.

olduser_welcome_message(JID) ->
    {"Welcome back, ~s. Since your follower/followee lists were deleted when " ++
     "you removed your account previously, you will need to build them again.",
     [jlib:jid_to_string(jlib:jid_remove_resource(JID))]}.

newuser_welcome_message(JID) ->
    {"Hello, ~s. I am Rabbiter, a bot for group communication. " ++
     "Please type 'help' (without the quotes) to learn how to interact with me!",
     [jlib:jid_to_string(jlib:jid_remove_resource(JID))]}.

send_presence(From, To, "") ->
    ?IDEBUG("Sending sub reply of type ((available))~n~p -> ~p", [From, To]),
    ejabberd_router:route(From, To, {xmlelement, "presence", [], []});
send_presence(From, To, TypeStr) ->
    ?IDEBUG("Sending sub reply of type ~p~n~p -> ~p", [TypeStr, From, To]),
    ejabberd_router:route(From, To, {xmlelement, "presence", [{"type", TypeStr}], []}).

send_chat(From, To, {Fmt, Args}) ->
    send_chat(From, To, io_lib:format(Fmt, Args));
send_chat(From, To, IoList) ->
    send_message(From, To, "chat", lists:flatten(IoList)).

send_message(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "message",
	       [{"type", TypeStr},
		{"from", jlib:jid_to_string(From)},
		{"to", jlib:jid_to_string(To)}],
	       [{xmlelement, "body", [],
		 [{xmlcdata, BodyStr}]}]},
    ?IDEBUG("Delivering ~p -> ~p~n~p", [From, To, XmlBody]),
    ejabberd_router:route(From, To, XmlBody).

probe_queues(Server) ->
    probe_queues(Server, rabbit_amqqueue:list_vhost_queues(?VHOST)).

probe_queues(_Server, []) ->
    ok;
probe_queues(Server, [#amqqueue{name = #resource{name = Urn}} | Rest]) ->
    case urn_to_jid(Urn) of
	{ok, JID} ->
	    ?IDEBUG("**** Initial probe of ~p", [Urn]),
	    probe_jid(jlib:make_jid(?BOTNAME, Server, ""), JID);
	{error, _Why} ->
	    ?IDEBUG("**** Ignoring ~p: ~p", [Urn, _Why])
    end,
    probe_queues(Server, Rest).

probe_jid(From, To) ->
    ?IDEBUG("**** Probing~n~p~n~p", [To, From]),
    send_presence(From, To, "probe"),
    send_presence(From, To, "").

start_consumer(Urn, JID, Server, Priority) ->
    case mnesia:transaction(
	   fun () ->
		   case mnesia:read({rabbiter_consumer_process, Urn}) of
		       [#rabbiter_consumer_process{pid = Pid}] ->
			   {existing, Pid};
		       [] ->
			   %% TODO: Link into supervisor
			   Pid = spawn(?MODULE, consumer_init, [Urn, JID, Server, Priority]),
			   mnesia:write(#rabbiter_consumer_process{queue = Urn, pid = Pid}),
			   {new, Pid}
		   end
	   end) of
	{atomic, {new, _Pid}} ->
	    ok;
	{atomic, {existing, Pid}} ->
	    Pid ! {presence, JID, Priority},
	    ok
    end.

stop_consumer(Urn, AllOrJID) ->
    mnesia:transaction(
      fun () ->
	      case mnesia:read({rabbiter_consumer_process, Urn}) of
		  [#rabbiter_consumer_process{pid = Pid}] ->
		      Pid ! {unavailable, AllOrJID},
		      ok;
		  [] ->
		      ok
	      end
      end),
    ok.

%% @hidden
consumer_init(Urn, JID, Server, Priority) ->
    ?INFO_MSG("**** starting consumer for queue ~p~njid ~p~npriority ~p",
	      [Urn, JID, Priority]),
    SelfPid = self(),
    spawn_link(fun () ->
		       erlang:monitor(process, SelfPid),
		       wait_for_death()
	       end),
    ConsumerTag = rabbit_misc:binstring_guid("rabbiter"),
    rabbit_amqqueue:with(?QNAME(Urn),
			 fun(Q) ->
				 rabbit_amqqueue:basic_consume(
				   Q, true, self(), self(),
				   ConsumerTag, false, undefined)
			 end),
    ?MODULE:consumer_main(#consumer_state{lserver = Server,
					  consumer_tag = ConsumerTag,
					  queue = Urn,
					  priorities = [{-Priority, JID}]}).

wait_for_death() ->
    receive
	{'DOWN', _Ref, process, _Pid, _Reason} ->
	    done;
	Other ->
	    exit({wait_for_death, unexpected, Other})
    end.

%% @hidden
consumer_main(#consumer_state{lserver = Server, queue = Urn} = State) ->
    case catch consumer_main_iter(State) of
	{'EXIT', Reason} ->
	    ?INFO_MSG("**** consumer death:~n~p~n~p", [State, Reason]),
	    consumer_done(State),
	    {ok, RemoteJid} = urn_to_jid(Urn),
	    probe_jid(jlib:make_jid(?BOTNAME, Server, ""), RemoteJid);
	{done, FinalState} ->
	    consumer_done(FinalState),
	    done;
	{ok, NewState} ->
	    ?MODULE:consumer_main(NewState)
    end.

consumer_main_iter(#consumer_state{priorities = Priorities} = State) ->
    ?IDEBUG("**** consumer ~p", [State]),
    receive
	{unavailable, AllOrJID} ->
	    NewPriorities = case AllOrJID of
				all ->
				    ?INFO_MSG("**** terminating consumer~n~p",
					      [State#consumer_state.queue]),
				    [];
				JID ->
				    lists:keydelete(JID, 2, Priorities)
			    end,
	    NewState = State#consumer_state{priorities = NewPriorities},
	    case NewPriorities of
		[] -> {done, NewState};
		_ -> {ok, NewState}
	    end;
	{presence, JID, Priority} ->
	    NewPriorities = lists:keysort(1, keystore(JID, 2, Priorities, {-Priority, JID})),
	    {ok, State#consumer_state{priorities = NewPriorities}};
	{deliver, _ConsumerTag, false, {_QName, _QPid, _Id, _Redelivered, Msg}} ->
	    #basic_message{exchange_name = #resource{name = XNameBin},
			   routing_key = RKBin,
			   content = Content0} = Msg,
	    Content = rabbit_binary_parser:ensure_content_decoded(Content0),
	    #content{properties = #'P_basic'{content_type = MimeTypeBin},
		     payload_fragments_rev = PayloadRev} = Content,
	    [{_, TopPriorityJID} | _] = Priorities,
	    handle_delivery(jlib:make_jid(?BOTNAME, State#consumer_state.lserver, ""),
			    TopPriorityJID,
			    XNameBin,
			    RKBin,
			    MimeTypeBin,
			    list_to_binary(lists:reverse(PayloadRev))),
	    {ok, State};
	Other ->
	    ?INFO_MSG("Consumer main ~p got~n~p", [State#consumer_state.queue, Other]),
	    {ok, State}
    end.

consumer_done(#consumer_state{queue = Urn, consumer_tag = ConsumerTag}) ->
    mnesia:transaction(fun () -> mnesia:delete({rabbiter_consumer_process, Urn}) end),
    rabbit_amqqueue:with(?QNAME(Urn),
			 fun (Q) ->
				 rabbit_amqqueue:basic_cancel(Q, self(), ConsumerTag, undefined)
			 end),
    ok.

handle_delivery(BotJid, TargetJid, _XNameBin, _RoutingKey, ?RABBITER_MIME_TYPE, BodyBin) ->
    Term = binary_to_term(BodyBin),
    case Term of
	{notify, FromUrn, follow} ->
	    send_chat(BotJid, TargetJid,
		      {"~s decided to follow you.",
		       [urn_to_string(FromUrn)]});
	{notify, FromUrn, unfollow} ->
	    send_chat(BotJid, TargetJid,
		      {"~s decided to stop following you.",
		       [urn_to_string(FromUrn)]});
	Other ->
	    send_chat(BotJid, TargetJid,
		      {"Hmm. An odd notification arrived to be presented to you, but " ++
		       "I don't understand it. Perhaps you do. Here it is:~n~p",
		       [Other]})
    end;
handle_delivery(BotJid, TargetJid, XNameBin, _RoutingKey, <<"text/plain">>, BodyBin) ->
    Body = binary_to_list(BodyBin),
    case urn_to_jid(XNameBin) of
	{error, _} ->
	    send_chat(BotJid, TargetJid,
		      {"A message from exchange ~p has arrived for you:~n~s",
		       [XNameBin, Body]});
	{ok, SourceJid} ->
	    case Body of
		"/me" ++ Rest ->
		    send_chat(BotJid, TargetJid, {"~s~s", [jlib:jid_to_string(SourceJid), Rest]});
		_ ->
		    Who = case jids_equal_upto_resource(SourceJid, TargetJid) of
			      true -> "you";
			      false -> jlib:jid_to_string(SourceJid)
			  end,
		    send_chat(BotJid, TargetJid, {"from ~s: ~s", [Who, Body]})
	    end
    end.

jids_equal_upto_resource(J1, J2) ->
    jlib:jid_remove_resource(J1) == jlib:jid_remove_resource(J2).

%% implementation from R12B-0. When we drop support for R11B, we can
%% use the system's implementation.
keystore(Key, N, [H|T], New) when element(N, H) == Key ->
    [New|T];
keystore(Key, N, [H|T], New) ->
    [H|keystore(Key, N, T, New)];
keystore(_Key, _N, [], New) ->
    [New].

parse_command("help") ->
    {"help", []};
parse_command("*" ++ Str) ->
    [Cmd | Args] = string:tokens(Str, " "),
    {stringprep:tolower(Cmd), Args};
parse_command(Str) ->
    {"say", [Str]}.

command_list() ->
    [{"help", "'*help (command)'. Provides help for other commands."},
     {"follow", "'*follow (jid)'. Receive broadcasts from the named jid."},
     {"unfollow", "'*unfollow (jid)'. No longer receive broadcasts from the named jid."},
     {"following", "'*following'. List all JIDs that you are following. '*following (jid)'. List all JIDs that the named person is following."},
     {"followers", "'*followers'. List all JIDs that are following you. '*followers (jid)'. List all JIDs that are following the named person."},
     {"invite", "'*invite (jid)'. Invites a JID to Rabbiter."}].

command_names() ->
    ["*" ++ Cmd || {Cmd, _} <- command_list()].

do_command(_To, _From, _RawCommand, {"help", []}) ->
    {ok,
     "To give me a command, choose one from the list below. Make sure you prefix it with '*', otherwise I'll interpret it as something you want to send to your group of followers. You can say '*help (command)' to get details on a command you're interested in. If you want to actually say 'help', rather than asking for help, type '*say help' instead.~n~p",
     [command_names()]};
do_command(_To, _From, _RawCommand, {"help", [Cmd0 | _]}) ->
    Cmd = case Cmd0 of
	      "*" ++ Suffix -> Suffix;
	      _ -> Cmd0
	  end,
    case lists:keysearch(stringprep:tolower(Cmd), 1, command_list()) of
	{value, {_, HelpText}} ->
	    {ok, HelpText};
	false ->
	    {ok, "Unknown command ~p. Try plain old '*help'.", [Cmd]}
    end;
do_command(To, From, _RawCommand, {"follow", [JidStr]}) ->
    use_user_supplied_jid(
      To, From, JidStr,
      fun (FolloweeUrn) ->
	      case rabbit_exchange:lookup(?XNAME(FolloweeUrn)) of
		  {error, not_found} ->
		      {error,
		       "I don't know that person. Perhaps you could invite them to get in touch?"};
		  {ok, _X} ->
		      FollowerUrn = jid_to_urn(From),
		      rabbit_amqqueue:add_binding(?QNAME(FollowerUrn),
						  ?XNAME(FolloweeUrn),
						  <<>>,
						  []),
		      send_notify(FollowerUrn, FolloweeUrn, follow),
		      {ok, "You are now following ~s.", [JidStr]}
	      end
      end);
do_command(To, From, _RawCommand, {"unfollow", [JidStr]}) ->
    use_user_supplied_jid(
      To, From, JidStr,
      fun (FolloweeUrn) ->
	      case rabbit_amqqueue:delete_binding(?QNAME(jid_to_urn(From)),
						  ?XNAME(FolloweeUrn),
						  <<>>,
						  []) of
		  {error, _Reason} ->
		      {error,
		       "I couldn't unfollow from JID ~s; either I don't know that person, " ++
		       "or you weren't following them. You might try '*following' to see " ++
		       "a list of all the people you are following.",
		       [JidStr]};
		  {ok, _PositiveCountOfBindings} ->
		      send_notify(jid_to_urn(From), FolloweeUrn, unfollow),
		      {ok, "You are now no longer following ~s.", [JidStr]}
	      end
      end);
do_command(_To, From, _RawCommand, {"following", []}) ->
    case lookup_following(jid_to_urn(From)) of
	{ok, []} ->
	    {ok, "You are not following anyone at the moment."};
	{ok, PrettyNames} ->
	    {ok, "You are currently following ~s.", [and_join(PrettyNames)]};
	{error, not_found} ->
	    {error, "That's odd. I couldn't retrieve the list of people you're following!"}
    end;
do_command(_To, _From, _RawCommand, {"following", [JidStr]}) ->
    case lookup_following(string_to_urn(JidStr)) of
	{ok, []} ->
	    {ok, "~s is not following anyone at the moment.", [JidStr]};
	{ok, PrettyNames} ->
	    {ok, "~s is currently following ~s.", [JidStr, and_join(PrettyNames)]};
	{error, not_found} ->
	    {error,
	     "I can't retrieve the list of people ~s is following. " ++
	     "Perhaps they are not a registered user?",
	     [JidStr]}
    end;
do_command(_To, From, _RawCommand, {"followers", []}) ->
    case lookup_followers(jid_to_urn(From)) of
	{ok, []} ->
	    {ok, "No-one is currently following you."};
	{ok, PrettyNames} ->
	    {ok, "You are currently being followed by ~s.", [and_join(PrettyNames)]}
    end;
do_command(_To, From, _RawCommand, {"followers", [JidStr]}) ->
    case lookup_followers(string_to_urn(JidStr)) of
	{ok, []} ->
	    {ok, "No-one is currently following ~s.", [JidStr]};
	{ok, PrettyNames} ->
	    {ok, "~s is currently being followed by ~s.", [JidStr, and_join(PrettyNames)]}
    end;
do_command(To, From, _RawCommand, {"invite", [JidStr]}) ->
    use_user_supplied_jid(
      To, From, JidStr,
      fun (UrnToInvite) ->
	      case rabbit_exchange:lookup(?XNAME(UrnToInvite)) of
		  {error, not_found} ->
		      {ok, JidToInvite} = urn_to_jid(UrnToInvite),
		      send_presence(To, JidToInvite, "subscribe"),
		      {ok, "I've sent an invitation off to ~s.", [JidStr]};
		  {ok, _X} ->
		      {error,
		       "They're already a user of the system! " ++
		       "You could try *following them, if you like."}
	      end
      end);
do_command(_To, From, _RawCommand, {"say", [Utterance | _]}) ->
    Urn = jid_to_urn(From),
    publish(Urn, <<"say">>, <<"text/plain">>, list_to_binary(Utterance)),
    noreply;
do_command(_To, _From, RawCommand, _Parsed) ->
    {error,
     "I didn't understand your command ~s.~n" ++
     "Here is a list of commands:~n~p",
     [RawCommand, command_names()]}.

and_join([S]) ->
    S;
and_join([A,B]) ->
    A ++ " and " ++ B;
and_join([S|Rest]) ->
    S ++ ", " ++ and_join(Rest).

send_notify(FromUrn, ToUrn, Notification) ->
    publish(<<>>, ToUrn, ?RABBITER_MIME_TYPE, term_to_binary({notify, FromUrn, Notification})).

publish(Urn, RKBin, MimeTypeBin, BodyBin) ->
    rabbit_exchange:simple_publish(false, false, ?XNAME(Urn), RKBin, MimeTypeBin, BodyBin).

send_command_reply(From, To, {Status, Fmt, Args}) ->
    send_command_reply(From, To, {Status, io_lib:format(Fmt, Args)});
send_command_reply(From, To, {ok, ResponseIoList}) ->
    send_chat(From, To, ResponseIoList);
send_command_reply(From, To, {error, ResponseIoList}) ->
    send_chat(From, To, ResponseIoList);
send_command_reply(_From, _To, noreply) ->
    ok.

prettify_urn_jids(_ExcludeU, []) ->
    [];
prettify_urn_jids(ExcludeU, [U | Rest])
  when ExcludeU == U ->
    prettify_urn_jids(ExcludeU, Rest);
prettify_urn_jids(ExcludeU, [U | Rest]) ->
    case urn_to_jid(U) of
	{error, invalid_format} ->
	    prettify_urn_jids(ExcludeU, Rest);
	{ok, J} ->
	    [jlib:jid_to_string(J) | prettify_urn_jids(ExcludeU, Rest)]
    end.

use_user_supplied_jid(BotJid, FromJid, JidStr, F) ->
    FromUrn = jid_to_urn(FromJid),
    case rabbit_exchange:lookup(?XNAME(FromUrn)) of
	{error, not_found} ->
	    send_presence(BotJid, FromJid, "subscribe"),
	    {error,
	     "I'm sorry - Something must have gone wrong in the authorisation process. " ++
	     "I've resent an authorisation request to you. Once that's all done, please try " ++
	     "this command again."};
	{ok, _X} ->
	    ?IDEBUG("use_user_supplied_jid found exchange ~p~n~p", [?XNAME(FromUrn), _X]),
	    case jlib:string_to_jid(JidStr) of
		error -> {error,
			  "That's not a valid JID. JIDs are of the form username@host.name"};
		JID -> F(jid_to_urn(JID))
	    end
    end.

lookup_following(Urn) ->
    case rabbit_amqqueue:lookup(?QNAME(Urn)) of
	{ok, #amqqueue{binding_specs = Specs}} ->
	    XNames = [XName || #binding_spec{exchange_name = #resource{name = XName}} <- Specs],
	    {ok, prettify_urn_jids(Urn, XNames)};
	{error, not_found} ->
	    {error, not_found}
    end.

lookup_followers(Urn) ->
    {atomic, QNames} =
	mnesia:transaction(
	  fun () ->
		  [QName || {#resource{name = QName}, _, _}
				<- rabbit_exchange:list_exchange_bindings(?XNAME(Urn))]
	  end),
    {ok, prettify_urn_jids(Urn, QNames)}.
