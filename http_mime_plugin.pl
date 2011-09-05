/*  $Id$

    Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        jan@swi.psy.uva.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 1985-2002, University of Amsterdam

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

:- module(http_mime_plugin, []).
:- use_module(http_client).
:- use_module(library(memfile)).
:- use_module(library(mime)).

/** <module> MIME client plugin

This plugin for library(http_client)   automatically translates messages
with content-type =|multipart/form-data|= into a list   of  Name = Value
pairs, greatly simplifying the processing of   forms  with this type. It
relies  on  library(mime),  which  in   turn    relies   on   a  foreign
implementation of the rfc2045 (mime) specifications.
*/

:- multifile
	http_client:http_convert_data/4,
	http_parameters:form_data_content_type/1.

%%	http_client:http_convert_data(+In, +Fields, -Data, +Options) is semidet.
%
%	Convert =|multipart/form-data|= messages for http_read_data/3.

http_client:http_convert_data(In, Fields, Data, Options) :-
	memberchk(content_type(Type), Fields),
	(   memberchk(mime_version(MimeVersion), Fields)
	;   sub_atom(Type, 0, _, _, 'multipart/form-data'),
	    MimeVersion = '1.0'
	), !,
	setup_call_cleanup(new_memory_file(MemFile),
			   convert_mime_data(In, Fields, Data,
					     MemFile, Type, MimeVersion, Options),
			   free_memory_file(MemFile)).

convert_mime_data(In, Fields, Data, MemFile, Type, MimeVersion, Options) :-
	setup_call_cleanup(open_memory_file(MemFile, write, Tmp),
			   ( format(Tmp, 'Mime-Version: ~w\r\n', [MimeVersion]),
			     format(Tmp, 'Content-Type: ~w\r\n\r\n', [Type]),
			     http_read_data(Fields, _,
					    [ in(In),
					      to(stream(Tmp))
					    | Options
					    ])
			   ),
			   close(Tmp)),
	setup_call_cleanup(open_memory_file(MemFile, read, MimeIn),
			   mime_parse(stream(MimeIn), Data0),
			   close(MimeIn)),
	mime_to_form(Data0, Data).

mime_to_form(mime(A,'',Parts), Form) :-
	memberchk(type('multipart/form-data'), A),
	mime_form_fields(Parts, Form), !.
mime_to_form(Mime, Mime).

mime_form_fields([], []).
mime_form_fields([mime(A, V, [])|T0], [Name=V|T]) :-
	memberchk(name(Name), A),
	mime_form_fields(T0, T).

http_parameters:form_data_content_type(ContentType) :-
	sub_atom(ContentType, 0, _, _, 'multipart/form-data').
