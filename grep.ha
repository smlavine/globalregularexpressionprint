// globalregularexpressionprint - search a file for a pattern
// Copyright (C) 2022 Sebastian LaVine <mail@smlavine.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

use bufio;
use bytes;
use encoding::utf8;
use fmt;
use fs;
use getopt;
use io;
use os;
use regex;
use strings;

// Meaningful exit statuses.
// See grep(1p), "EXIT STATUS".
type status = enum {
	SELECTED,
	NONE_SELECTED,
	ERROR,
};

// Converts a BRE to an ERE.
// The regex module only matches EREs, but grep(1p) matches BREs by default.
fn bre_to_ere(s: *str) (void | utf8::invalid) = {
	let r = strings::toutf8(*s);

	const chars: [_]u8 = ['?', '+', '(', ')', '{', '}', '|'];

	for (let n = 0z; n < len(chars); n += 1) {
		for (let upto = 0z; upto < len(r)) {
			let index = match (bytes::index(r[upto..], chars[n])) {
			case void =>
				break;
			case let i: size =>
				yield upto + i;
			};

			// Ex. "\+" => "+", "+" => "\+"
			if (index != 0 && r[index - 1] == '\\') {
				delete(r[index - 1]);
				upto = index + 1;
			} else {
				insert(r[index], '\\');
				upto = index + 2;
			};
		};
	};

	*s = strings::fromutf8(r)?;
};

// Opens a file. This is a wrapper around [[os::open]].
// If the path is equal to "-", then [[os::stdin]] is returned instead.
// On failure, an error message is printed, unless the -s option is present.
fn openfile(path: str) (io::handle | void) = {
	if (path == "-") {
		return os::stdin;
	};
	match (os::open(path)) {
	case let e: fs::error =>
		// TODO: -s error message suppression
		fmt::errorfln("{}: {}: {}",
			os::args[0],
			path,
			fs::strerror(e),
		)!;
		return void;
	case let f: io::file =>
		return f;
	};
};

// Prints the contents of all given files to stdout.
// This should be invoked if an empty pattern_list is provided; the grep
// standard states that "[a] null [BRE, ERE] shall match every line."
// If no names are provided, then stdin is copied to stdout instead.
// The amount of non-fatal errors encountered while executing the function is
// returned.
fn print_all_files(names: []str) uint = {
	if (len(names) == 0) {
		io::copy(os::stdout, os::stdin)!;
		return 0;
	};

	let erroramt: uint = 0;
	for (let i = 0z; i < len(names); i += 1) {
		const f = match (openfile(names[i])) {
		case void =>
			erroramt += 1;
			continue;
		case let f: io::handle =>
			yield f;
		};
		defer io::close(f): void;
		match (io::copy(os::stdout, f)) {
		case let e: io::error =>
			// TODO: -s error message suppression
			fmt::errorfln("{}: {}: {}",
				os::args[0],
				names[i],
				io::strerror(e),
			)!;
			erroramt += 1;
		case size => void;
		};
	};

	return erroramt;
};

// Prints the lines from file that match at least one of the patterns.
// On error, the amount of non-fatal errors encountered while executing the
// function is returned. Otherwise, whether or not the file matched at least
// one of the patterns is returned.
// TODO: Add a better way of determining error for exit status than returning
// the amount of errors and summing them. It doesn't make sense for this
// interface.
fn search(
	file: io::handle,
	name: str,
	patterns: []regex::regex,
) (uint | bool) = {
	let selected = false;
	for (true) {
		// TODO: io::drain => strings::tokenize(s, "\n") instead of
		// reading one line at a time like this, except if file is a
		// tty, then maintain the instant feedback of whether a line
		// matches or not.
		// It looks like to accomodate this, we will have to use
		// io::file and os::stdin_file instead of io::handle and
		// os::stdin here, since unix::tty::isatty takes a io::file.
		// Or we can just forget about it.
		let line = match (bufio::scanline(file)) {
		case let e: io::error =>
			// TODO: -s error message suppression
			fmt::errorfln("{}: {}: {}",
				os::args[0],
				name,
				io::strerror(e),
			)!;
			return 1;
		case io::EOF =>
			break;
		case let s: []u8 =>
			yield strings::fromutf8(s)!;
		};
		defer free(line);

		for (let i = 0z; i < len(patterns); i += 1) {
			if (regex::test(&patterns[i], line)) {
				// TODO: when there is more than one file
				// provided to the program, this must
				// print the file name as a prefix.
				fmt::println(line)!;
				if (!selected) selected = true;
			};
		};
	};
	return selected;
};

export fn main() void = {
	const help: []getopt::help = [
		"search a file for a pattern",
		"pattern_list",
		"[file...]",
	];
	const cmd = getopt::parse(os::args, help...);
	defer getopt::finish(&cmd);

	if (len(cmd.args) == 0) {
		getopt::printusage(os::stderr, os::args[0], help);
		os::exit(status::ERROR);
	};

	if (bre_to_ere(&cmd.args[0]) is utf8::invalid) {
		fmt::fatal("Invalid UTF-8 sequence in pattern");
	};

	const patterns: []regex::regex = {
		let patterns: []regex::regex = [];
		const lines = strings::tokenize(cmd.args[0], "\n");
		for (let pat = strings::next_token(&lines);
			pat is str;
			pat = strings::next_token(&lines)
		) {
			match (regex::compile(pat as str)) {
			case let e: regex::error =>
				fmt::fatalf("{}: {}",
					os::args[0],
					regex::strerror(e),
				);
			case let r: regex::regex =>
				append(patterns, r);
			};
		};
		yield patterns;
	};
	defer {
		for (let i = 0z; i < len(patterns); i += 1) {
			regex::finish(&patterns[i]);
		};
		free(patterns);
	};

	// Used to determine the correct exit status to use.
	// TODO: improve/get rid of
	let erroramt: uint = 0;
	let selected = false;

	if (len(patterns) == 0) {
		// "A null [BRE, ERE] shall match every line."
		erroramt += print_all_files(cmd.args[1..]);
	} else if (len(cmd.args) == 1) {
		match (search(os::stdin, "<stdin>", patterns)) {
		case let u: uint =>
			erroramt += u;
		case let b: bool =>
			if (!selected && b) {
				selected = true;
			};
		};
	} else {
		for (let i = 1z; i < len(cmd.args); i += 1) {
			const f = match (openfile(cmd.args[i])) {
			case void =>
				erroramt += 1;
				continue;
			case let f: io::handle =>
				yield f;
			};
			defer io::close(f): void;
			match (search(f, cmd.args[i], patterns)) {
			case let u: uint =>
				erroramt += u;
			case let b: bool =>
				if (!selected && b) {
					selected = true;
				};
			};
		};
	};

	if (erroramt == 0) {
		if (selected) {
			os::exit(status::SELECTED);
		} else {
			os::exit(status::NONE_SELECTED);
		};
	} else {
		os::exit(status::ERROR);
	};
};
