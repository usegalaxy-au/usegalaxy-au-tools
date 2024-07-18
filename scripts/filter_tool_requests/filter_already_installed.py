"""Filter out tools that are already installed."""

import argparse
import yaml
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("tools_yml_file", help="Path to the request.yml file")
parser.add_argument('-j', '--jenkins-output-file',
                    required=False,
                    dest="jenkins_output_file",
                    help="Path to the tools.yml file",
                    default="jenkins_output.txt")
args = parser.parse_args()


def main():

    with open(args.tools_yml_file) as f:
        print(f"Reading tools from {args.tools_yml_file}")
        tools = yaml.safe_load(f)

    print("Filtering already installed tools")
    exclude_tool_ids = _get_excluded_tool_ids()
    filtered_tools = [
        tool
        for tool in tools['tools']
        if tool['name'] not in exclude_tool_ids
    ]
    tools['tools'] = filtered_tools

    outfile = Path(args.tools_yml_file).stem + "_filtered.yml"
    with open(outfile, 'w') as f:
        print(f"Writing filtered tools to {outfile}")
        yaml.dump(tools, f)


def _get_excluded_tool_ids():
    print(f"Reading excluded tools from {args.jenkins_output_file}")
    with open(args.jenkins_output_file) as f:
        errors = [
            x.strip()
            for x in f.read().split('\n')
            if x.strip()
        ]
    remove_tool_ids = []
    for line in errors:
        if "different section" in line:
            remove_tool_ids.append(line.split()[2])
    return remove_tool_ids


if __name__ == '__main__':
    main()
