use bytes;
use fmt;
use getopt;
use io;
use os;
use strings;

// Converts a BRE to an ERE. The string provided is modified in-place.
fn bre_to_ere(s: *str) void = {
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

	*s = strings::fromutf8(r);
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
		os::exit(1);
	};

	bre_to_ere(&cmd.args[0]);

	fmt::println(cmd.args[0])!; // DEBUG: REMOVE
};
