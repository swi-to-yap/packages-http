/*  Part of SWI-Prolog

    Author:        Jan Wielemaker, Matt Lilley
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2006-2013, University of Amsterdam
			      VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/


:- module(http_session,
	  [ http_set_session_options/1,	% +Options
	    http_set_session/1,		% +Option
	    http_session_option/1,	% ?Option

	    http_session_id/1,		% -SessionId
	    http_in_session/1,		% -SessionId
	    http_current_session/2,	% ?SessionId, ?Data
	    http_close_session/1,	% +SessionId
            http_open_session/2,	% -SessionId, +Options

	    http_session_cookie/1,	% -Cookie

	    http_session_asserta/1,	% +Data
	    http_session_assert/1,	% +Data
	    http_session_retract/1,	% ?Data
	    http_session_retractall/1,	% +Data
	    http_session_data/1		% ?Data
	  ]).
:- use_module(http_wrapper).
:- use_module(http_stream).
:- use_module(library(error)).
:- use_module(library(debug)).
:- use_module(library(socket)).
:- use_module(library(broadcast)).
:- use_module(library(lists)).

:- predicate_options(http_open_session/2, 2, [renew(boolean)]).

/** <module> HTTP Session management
@ingroup http

This library defines session management based   on HTTP cookies. Session
management is enabled simply by  loading   this  module.  Details can be
modified  using  http_set_session_options/1.  By  default,  this  module
creates a session whenever a request  is   processes  that is inside the
hierarchy  defined  for   session   handling    (see   path   option  in
http_set_session_options/1. Automatic creation  of  a   session  can  be
stopped    using    the    option    create(noauto).    The    predicate
http_open_session/2 must be used to  create   a  session  if =noauto= is
enabled. Sessions can be closed using http_close_session/1.

If a session is active, http_in_session/1   returns  the current session
and http_session_assert/1 and friends maintain   data about the session.
If the session is reclaimed, all associated data is reclaimed too.

Begin and end of sessions can be monitored using library(broadcast). The
broadcasted messages are:

    * http_session(begin(SessionID, Peer))
    Broadcasted if a session is started
    * http_session(end(SessionId, Peer))
    Broadcasted if a session is ended. See http_close_session/1.

For example, the  following  calls   end_session(SessionId)  whenever  a
session terminates. Please note that sessions  ends are not scheduled to
happen at the actual timeout moment of  the session. Instead, creating a
new session scans the  active  list   for  timed-out  sessions. This may
change in future versions of this library.

    ==
    :- listen(http_session(end(SessionId, Peer)),
	      end_session(SessionId)).
    ==
*/

:- dynamic
	session_setting/1,		% Name(Value)
	current_session/2,		% SessionId, Peer
	last_used/2,			% SessionId, Time
	session_data/2.			% SessionId, Data

session_setting(timeout(600)).		% timeout in seconds
session_setting(cookie('swipl_session')).
session_setting(path(/)).
session_setting(enabled(true)).
session_setting(create(auto)).
session_setting(proxy_enabled(false)).

session_option(timeout, integer).
session_option(cookie, atom).
session_option(path, atom).
session_option(create, oneof([auto,noauto])).
session_option(route, atom).
session_option(enabled, boolean).
session_option(proxy_enabled, boolean).

%%	http_set_session_options(+Options) is det.
%
%	Set options for the session library.  Provided options are:
%
%		* timeout(+Seconds)
%		Session timeout in seconds.  Default is 600 (10 min).
%
%		* cookie(+Cookiekname)
%		Name to use for the cookie to identify the session.
%		Default =swipl_session=.
%
%		* path(+Path)
%		Path to which the cookie is associated.  Default is
%		=|/|=.	Cookies are only sent if the HTTP request path
%		is a refinement of Path.
%
%		* route(+Route)
%		Set the route name. Default is the unqualified
%		hostname. To cancel adding a route, use the empty
%		atom.  See route/1.
%
%		* enabled(+Boolean)
%		Enable/disable session management.  Sesion management
%		is enabled by default after loading this file.
%
%		* create(+Atom)
%		Defines when a session is created. This is one of =auto=
%		(default), which creates a session if there is a request
%		whose path matches the defined session path or =noauto=,
%		in which cases sessions are only created by calling
%		http_open_session/2 explicitely.
%
%		* proxy_enabled(+Boolean)
%		Enable/disable proxy session management. Proxy session
%		management associates the _originating_ IP address of
%		the client to the session rather than the _proxy_ IP
%		address. Default is false.

http_set_session_options([]).
http_set_session_options([H|T]) :-
	http_set_session_option(H),
	http_set_session_options(T).

http_set_session_option(Option) :-
	functor(Option, Name, Arity),
	arg(1, Option, Value),
	(   session_option(Name, Type)
	->  must_be(Type, Value)
	;   domain_error(http_session_option, Option)
	),
	functor(Free, Name, Arity),
	retractall(session_setting(Free)),
	assert(session_setting(Option)).

%%	http_session_option(?Option) is nondet.
%
%	True if Option is a current option of the session system.

http_session_option(Option) :-
	session_setting(Option).

%%	session_setting(+SessionID, ?Setting) is semidet.
%
%	Find setting for SessionID. It  is   possible  to  overrule some
%	session settings using http_session_set(Setting).

session_setting(SessionId, Setting) :-
	nonvar(Setting),
	functor(Setting, Name, 1),
	local_option(Name, Value, Term),
	session_data(SessionId, '$setting'(Term)), !,
	arg(1, Setting, Value).
session_setting(_, Setting) :-
	session_setting(Setting).

%%	http_set_session(Setting) is det.
%
%	Overrule a setting for the current  session. Currently, the only
%	setting that can be overruled is =timeout=.
%
%	@error	permission_error(set, http_session, Setting) if setting
%		a setting that is not supported on per-session basis.

http_set_session(Setting) :-
	http_session_id(SessionId),
	functor(Setting, Name, Arity),
	(   local_option(Name, _, _)
	->  true
	;   permission_error(set, http_session, Setting)
	),
	arg(1, Setting, Value),
	(   session_option(Name, Type)
	->  must_be(Type, Value)
	;   domain_error(http_session_option, Setting)
	),
	functor(Free, Name, Arity),
	retractall(session_data(SessionId, '$setting'(Free))),
	assert(session_data(SessionId, '$setting'(Setting))).

local_option(timeout, X, timeout(X)).

%%	http_session_id(-SessionId) is det.
%
%	True if SessionId is an identifier for the current session.
%
%	@param SessionId is an atom.
%	@error existence_error(http_session, _)
%	@see   http_in_session/1 for a version that fails if there is
%	       no session.

http_session_id(SessionID) :-
	(   http_in_session(ID)
	->  SessionID = ID
	;   throw(error(existence_error(http_session, _), _))
	).

%%	http_in_session(-SessionId) is semidet.
%
%	True if SessionId is an identifier  for the current session. The
%	current session is extracted from   session(ID) from the current
%	HTTP request (see http_current_request/1). The   value is cached
%	in a backtrackable global variable   =http_session_id=.  Using a
%	backtrackable global variable is safe  because continuous worker
%	threads use a failure driven  loop   and  spawned  threads start
%	without any global variables. This variable  can be set from the
%	commandline to fake running a goal   from the commandline in the
%	context of a session.
%
%	@see http_session_id/1

http_in_session(SessionID) :-
	nb_current(http_session_id, ID),
	ID \== [], !,
	ID \== no_session,
	SessionID = ID.
http_in_session(SessionID) :-
	http_current_request(Request),
	http_in_session(Request, SessionID).

http_in_session(Request, SessionID) :-
	memberchk(session(ID), Request),
	b_setval(http_session_id, ID), !,
	SessionID = ID.
http_in_session(Request, SessionID) :-
	memberchk(cookie(Cookies), Request),
	session_setting(cookie(Cookie)),
	memberchk(Cookie=SessionID0, Cookies),
	peer(Request, Peer),
	valid_session_id(SessionID0, Peer), !,
	b_setval(http_session_id, SessionID0),
	SessionID = SessionID0.


%%	http_session(+RequestIn, -RequestOut, -SessionID) is semidet.
%
%	Maintain the notion of a  session   using  a client-side cookie.
%	This must be called first when handling a request that wishes to
%	do session management, after which the possibly modified request
%	must be used for further processing.
%
%	This predicate creates a  session  if   the  setting  create  is
%	=auto=.  If  create  is  =noauto=,  the  application  must  call
%	http_open_session/1 to create a session.

http_session(Request, Request, SessionID) :-
	memberchk(session(SessionID0), Request), !,
	SessionID = SessionID0.
http_session(Request0, Request, SessionID) :-
	memberchk(cookie(Cookies), Request0),
	session_setting(cookie(Cookie)),
	memberchk(Cookie=SessionID0, Cookies),
	peer(Request0, Peer),
	valid_session_id(SessionID0, Peer), !,
	SessionID = SessionID0,
	Request = [session(SessionID)|Request0],
	b_setval(http_session_id, SessionID).
http_session(Request0, Request, SessionID) :-
        session_setting(create(auto)),
	session_setting(path(Path)),
	memberchk(path(ReqPath), Request0),
	sub_atom(ReqPath, 0, _, _, Path), !,
	create_session(Request0, Request, SessionID).

create_session(Request0, Request, SessionID) :-
	http_gc_sessions,
	http_session_cookie(SessionID),
	session_setting(cookie(Cookie)),
	session_setting(path(Path)),
	format('Set-Cookie: ~w=~w; path=~w\r\n', [Cookie, SessionID, Path]),
	Request = [session(SessionID)|Request0],
	peer(Request0, Peer),
	open_session(SessionID, Peer),
	b_setval(http_session_id, SessionID).


%%	http_open_session(-SessionID, +Options) is det.
%
%	Establish a new session.  This is normally used if the create
%	option is set to =noauto=.  Options:
%
%	  * renew(+Boolean)
%	  If =true= (default =false=) and the current request is part
%	  of a session, generate a new session-id.  By default, this
%	  predicate returns the current session as obtained with
%	  http_in_session/1.
%
%	@see	http_set_session_options/1 to control the =create= option.
%	@see	http_close_session/1 for closing the session.
%	@error	permission_error(open, http_session, CGI) if this call
%		is used after closing the CGI header.

http_open_session(SessionID, Options) :-
	http_in_session(SessionID0),
	\+ option(renew(true), Options, false), !,
	SessionID = SessionID0.
http_open_session(SessionID, _Options) :-
	(   in_header_state
	->  true
	;   current_output(CGI),
	    permission_error(open, http_session, CGI)
	),
	(   http_in_session(ActiveSession)
	->  http_close_session(ActiveSession, false)
	;   true
	),
	http_current_request(Request),
	create_session(Request, _, SessionID).


:- multifile
	http:request_expansion/2.

http:request_expansion(Request0, Request) :-
	session_setting(enabled(true)),
	http_session(Request0, Request, _SessionID).

%%	peer(+Request, -Peer) is det.
%
%	Find peer for current request. If   unknown we leave it unbound.
%	Alternatively we should treat this as an error.

peer(Request, Peer) :-
	(   session_setting(proxy_enabled(true)),
	    http_peer(Request, Peer)
	->  true
	;   memberchk(peer(Peer), Request)
	->  true
	;   true
	).

%%	open_session(+SessionID, +Peer)
%
%	Open a new session.  Uses broadcast/1 with the term
%	http_session(begin(SessionID, Peer)).

open_session(SessionID, Peer) :-
	get_time(Now),
	assert(current_session(SessionID, Peer)),
	assert(last_used(SessionID, Now)),
	broadcast(http_session(begin(SessionID, Peer))).


%%	valid_session_id(+SessionID, +Peer) is semidet.
%
%	Check if this sessionID is known. If so, check the idle time and
%	update the last_used for this session.

valid_session_id(SessionID, Peer) :-
	current_session(SessionID, SessionPeer),
	get_time(Now),
	(   session_setting(SessionID, timeout(Timeout)),
	    Timeout > 0
	->  get_last_used(SessionID, Last),
	    Idle is Now - Last,
	    (	Idle =< Timeout
	    ->  true
	    ;   http_close_session(SessionID),
		fail
	    )
	;   Peer \== SessionPeer
	->  http_close_session(SessionID),
	    fail
	;   true
	),
	set_last_used(SessionID, Now).

get_last_used(SessionID, Last) :-
	atom(SessionID), !,
	with_mutex(http_session, last_used(SessionID, Last)).
get_last_used(SessionID, Last) :-
	with_mutex(http_session,
		   findall(SessionID-Last,
			   last_used(SessionID, Last),
			   Pairs)),
	member(SessionID-Last, Pairs).

set_last_used(SessionID, Now) :-
	with_mutex(http_session,
		  (   retractall(last_used(SessionID, _)),
		      assert(last_used(SessionID, Now)))).



		 /*******************************
		 *	   SESSION DATA		*
		 *******************************/

%%	http_session_asserta(+Data) is det.
%%	http_session_assert(+Data) is det.
%%	http_session_retract(?Data) is nondet.
%%	http_session_retractall(?Data) is det.
%
%	Versions of assert/1, retract/1 and retractall/1 that associate
%	data with the current HTTP session.

http_session_asserta(Data) :-
	http_session_id(SessionId),
	asserta(session_data(SessionId, Data)).

http_session_assert(Data) :-
	http_session_id(SessionId),
	assert(session_data(SessionId, Data)).

http_session_retract(Data) :-
	http_session_id(SessionId),
	retract(session_data(SessionId, Data)).

http_session_retractall(Data) :-
	http_session_id(SessionId),
	retractall(session_data(SessionId, Data)).

%%	http_session_data(?Data) is nondet.
%
%	True if Data is associated using http_session_assert/1 to the
%	current HTTP session.
%
%	@error	existence_error(http_session,_)

http_session_data(Data) :-
	http_session_id(SessionId),
	session_data(SessionId, Data).


		 /*******************************
		 *	     ENUMERATE		*
		 *******************************/

%%	http_current_session(?SessionID, ?Data) is nondet.
%
%	Enumerate the current sessions and   associated data.  There are
%	two _Pseudo_ data elements:
%
%		* idle(Seconds)
%		Session has been idle for Seconds.
%
%		* peer(Peer)
%		Peer of the connection.

http_current_session(SessionID, Data) :-
	get_time(Now),
	get_last_used(SessionID, Last),	% binds SessionID
	Idle is Now - Last,
	(   session_setting(SessionID, timeout(Timeout)),
	    Timeout > 0
	->  Idle =< Timeout
	;   true
	),
	(   Data = idle(Idle)
	;   Data = peer(Peer),
	    current_session(SessionID, Peer)
	;   session_data(SessionID, Data)
	).


		 /*******************************
		 *	    GC SESSIONS		*
		 *******************************/

%%	http_close_session(+SessionID) is det.
%
%	Closes an HTTP session. This predicate   can  be called from any
%	thread to terminate a session.  It uses the broadcast/1 service
%	with the message below.
%
%		http_session(end(SessionId, Peer))
%
%	The broadcast is done *before* the session data is destroyed and
%	the listen-handlers are executed in context  of the session that
%	is being closed. Here  is  an   example  that  destroys a Prolog
%	thread that is associated to a thread:
%
%	==
%	:- listen(http_session(end(SessionId, _Peer)),
%		  kill_session_thread(SessionID)).
%
%	kill_session_thread(SessionID) :-
%		http_session_data(thread(ThreadID)),
%		thread_signal(ThreadID, throw(session_closed)).
%	==
%
%	Succeed without any effect if  SessionID   does  not refer to an
%	active session.
%
%	If http_close_session/1 is called from   a  handler operating in
%	the current session  and  the  CGI   stream  is  still  in state
%	=header=, this predicate emits a   =|Set-Cookie|=  to expire the
%	cookie.
%
%	@error	type_error(atom, SessionID)
%	@see	listen/2 for acting upon closed sessions

http_close_session(SessionId) :-
	http_close_session(SessionId, true).

http_close_session(SessionId, Expire) :-
	must_be(atom, SessionId),
	(   current_session(SessionId, Peer),
	    (	b_setval(http_session_id, SessionId),
		broadcast(http_session(end(SessionId, Peer))),
		fail
	    ;	true
	    ),
	    (	Expire == true
	    ->	expire_session_cookie
	    ;	true
	    ),
	    retractall(current_session(SessionId, _)),
	    retractall(last_used(SessionId, _)),
	    retractall(session_data(SessionId, _)),
	    fail
	;   true
	).


%%	expire_session_cookie(+SessionId) is det.
%
%	Emit a request to delete a session  cookie. This is only done if
%	http_close_session/1 is still in `header mode'.

expire_session_cookie :-
	in_header_state,
	session_setting(cookie(Cookie)),
	session_setting(path(Path)), !,
	format('Set-Cookie: ~w=; \c
		expires=Tue, 01-Jan-1970 00:00:00 GMT; \c
		path=~w\r\n',
	       [Cookie, Path]).
expire_session_cookie.

in_header_state :-
	current_output(CGI),
	cgi_property(CGI, state(header)), !.


%%	http_gc_sessions is det.
%
%	Delete dead sessions. Currently runs session GC if a new session
%	is opened and the last session GC was more than a minute ago.

:- dynamic
	last_gc/1.

http_gc_sessions :-
	(   with_mutex(http_session_gc, need_sesion_gc)
	->  do_http_gc_sessions
	;   true
	).

need_sesion_gc :-
	get_time(Now),
	(   last_gc(LastGC),
	    Now-LastGC < 60
	->  true
	;   retractall(last_gc(_)),
	    asserta(last_gc(Now)),
	    do_http_gc_sessions
	).

do_http_gc_sessions :-
	get_time(Now),
	(   last_used(SessionID, Last),
	      session_setting(SessionID, timeout(Timeout)),
	      Timeout > 0,
	      Idle is Now - Last,
	      Idle > Timeout,
	        http_close_session(SessionID),
	    fail
	;   true
	).


		 /*******************************
		 *	       UTIL		*
		 *******************************/

%%	http_session_cookie(-Cookie) is det.
%
%	Generate a random cookie that  can  be   used  by  a  browser to
%	identify  the  current  session.  The   cookie  has  the  format
%	XXXX-XXXX-XXXX-XXXX[.<route>], where XXXX are random hexadecimal
%	numbers  and  [.<route>]  is  the    optionally   added  routing
%	information.

http_session_cookie(Cookie) :-
	route(Route), !,
	random_4(R1,R2,R3,R4),
	format(atom(Cookie),
		'~`0t~16r~4|-~`0t~16r~9|-~`0t~16r~14|-~`0t~16r~19|.~w',
		[R1,R2,R3,R4,Route]).
http_session_cookie(Cookie) :-
	random_4(R1,R2,R3,R4),
	format(atom(Cookie),
		'~`0t~16r~4|-~`0t~16r~9|-~`0t~16r~14|-~`0t~16r~19|',
		[R1,R2,R3,R4]).

:- thread_local
	route_cache/1.

%%	route(-RouteID) is semidet.
%
%	Fetch the route identifier. This value   is added as .<route> to
%	the session cookie and used  by   -for  example- the apache load
%	balanching module. The default route is   the  local name of the
%	host.     Alternatives     may      be       provided      using
%	http_set_session_options/1.

route(Route) :-
	route_cache(Route), !,
	Route \== ''.
route(Route) :-
	route_no_cache(Route),
	assert(route_cache(Route)),
	Route \== ''.

route_no_cache(Route) :-
	session_setting(route(Route)), !.
route_no_cache(Route) :-
	gethostname(Host),
	(   sub_atom(Host, Before, _, _, '.')
	->  sub_atom(Host, 0, Before, _, Route)
	;   Route = Host
	).

:- if(\+current_prolog_flag(windows, true)).
%%	urandom(-Handle) is semidet.
%
%	Handle is a stream-handle  for   /dev/urandom.  Originally, this
%	simply tried to open /dev/urandom, failing   if this device does
%	not exist. It turns out  that   trying  to open /dev/urandom can
%	block indefinitely on  some  Windows   installations,  so  we no
%	longer try this on Windows.

:- dynamic
	urandom_handle/1.

urandom(Handle) :-
	urandom_handle(Handle), !,
	Handle \== [].
urandom(Handle) :-
	catch(open('/dev/urandom', read, In, [type(binary)]), _, fail), !,
	assert(urandom_handle(In)),
	Handle = In.
urandom(_) :-
	assert(urandom_handle([])),
	fail.

get_pair(In, Value) :-
	get_byte(In, B1),
	get_byte(In, B2),
	Value is B1<<8+B2.
:- endif.

%%	random_4(-R1,-R2,-R3,-R4) is det.
%
%	Generate 4 2-byte random  numbers.   Uses  =|/dev/urandom|= when
%	available to make prediction of the session IDs hard.

:- if(current_predicate(urandom/1)).
random_4(R1,R2,R3,R4) :-
	urandom(In), !,
	get_pair(In, R1),
	get_pair(In, R2),
	get_pair(In, R3),
	get_pair(In, R4).
:- endif.
random_4(R1,R2,R3,R4) :-
	R1 is random(65536),
	R2 is random(65536),
	R3 is random(65536),
	R4 is random(65536).
