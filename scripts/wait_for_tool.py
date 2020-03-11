import argparse
import time
import sys

from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.toolshed import ToolShedClient

time_increment = 30


def main():
    parser = argparse.ArgumentParser(description='Wait for a tool revision to appear in a repository list for a Galaxy instance')
    parser.add_argument('-g', '--galaxy_url', help='Galaxy server URL')
    parser.add_argument('-a', '--api_key', help='API key for galaxy server')
    parser.add_argument('-n', '--name', help='Tool name')
    parser.add_argument('-o', '--owner', help='Tool owner')
    parser.add_argument('-r', '--revision', help='Changeset revision')
    parser.add_argument('-t', '--timeout', type=int, default=600, help='Time to wait in seconds')

    args = parser.parse_args()
    galaxy_url = args.galaxy_url
    api_key = args.api_key
    name = args.name
    owner = args.owner
    revision = args.revision
    timeout = args.timeout

    found_tool = False
    elapsed_sleep = 0
    while found_tool is False:
        if elapsed_sleep > timeout:
            raise Exception('Timeout exceeded')
        matches = None
        try:
            gal = GalaxyInstance(galaxy_url, api_key)
            cli = ToolShedClient(gal)
            u_repos = cli.get_repositories()
            matches = [t for t in u_repos if t['name'] == name and t['owner'] == owner and t['changeset_revision'] == revision]
        except Exception as e:
            sys.stderr.write('%s\n' % str(e))
            # Do nothing and wait for timeout
        if matches:
            found_tool = True
        else:
            sys.stderr.write('Waiting for tool on galaxy\n')
            elapsed_sleep += time_increment
            time.sleep(time_increment)


if __name__ == "__main__":
    main()
