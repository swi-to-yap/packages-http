/*  $Id$

    Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        wielemak@science.uva.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 1985-2005, University of Amsterdam

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

:- module(http_error,
	  [
	  ]).
:- use_module(library(prolog_stack)).
@ingroup http

/** <module> Decorate uncaught HTTP exceptions with stack-trace

This module decorates uncaught exceptions of the   user code with a full
stack-trace. It is based  on  a   hook  introduced  in SWI-Prolog 5.6.5.
Please  note  that  although  loading  this  module  greatly  simplifies
debugging, it also provides clues for hackers  on how to compromise your
site. The more information you give them, the easier it is to break into
your server!

To use this file, simply load it.

@author	Jan Wielemaker
*/

:- dynamic prolog_stack:stack_guard/1.
:- multifile prolog_stack:stack_guard/1.

prolog_stack:stack_guard(httpd_wrapper:call_handler/6).	% old version
prolog_stack:stack_guard(httpd_wrapper:wrapper/5).
prolog_stack:stack_guard(httpd_wrapper:handler_with_output_to/5).

