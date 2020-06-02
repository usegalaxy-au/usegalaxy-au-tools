import re
import argparse
import sys

"""
Find the first match from a pattern in a file.  This is designed to mimic
the functionality of bash regular expression matching.  This helper has been
written because bash versions earlier than 4 do not support regex matching.
"""


def main():
    parser = argparse.ArgumentParser(description='Mimic bash pattern matching')
    parser.add_argument('-p', '--pattern', help='Pattern to match')
    parser.add_argument('file_path', help='File in which to find first match')
    args = parser.parse_args()

    first_match_regex(args.file_path, args.pattern)


def first_match_regex(path, pattern):
    compiled_pattern = re.compile(
        pattern,
        re.MULTILINE,
    )
    with open(path) as logfile:
        matches = compiled_pattern.findall(logfile.read())
    if len(matches) > 0:
        match = matches[0] if not isinstance(matches[0], str) else [matches[0]]
        sys.stdout.write('%s' % ' '.join(match))  # value returned to shell through stdout


if __name__ == "__main__":
    main()
