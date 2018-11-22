#!/usr/bin/env perl

use warnings;
use strict;

my $pythonpath = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/python";
my $get_tools_command = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/get-tool-list";

my %apikeys = (
    "https://usegalaxy.org.au" => "1a8925423f32fe02878919df4b170ef9",
    "https://galaxy-aust-dev.genome.edu.au" => "a811534c3d566efe9e227967256bae60",
    "https://galaxy-aust-staging.genome.edu.au" => "d90a8b1fa0d432ee48daed1ac577fb89"
    );


foreach my $serv (keys %apikeys){

    print "Working on tool lists from server: $serv\n";
    my $outfile = $serv;
    $outfile =~ s/https:\/\///;
    $outfile =~ s/.genome.edu.au//;
    #print "$outfile\n";

    system("$pythonpath $get_tools_command -g $serv --get_data_managers --include_tool_panel_id -a $apikeys{$serv} -o $outfile.yml") == 0 or die { print "Failed at getting tools for $serv\n$!" };

    system("$pythonpath scripts/split_tool_yml.py -i $outfile.yml -o $outfile") == 0 or die { print "Failed at splitting tools for $serv\n$!" };

    unlink "$outfile.yml"

}
