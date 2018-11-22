#!/usr/bin/env perl

use warnings;
use strict;

my $pythonpath = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/python";
my $get_tools_command = "/Users/simongladman/miniconda3/envs/galaxy_training_material/bin/get-tool-list";

my %apikeys = (
    "https://usegalaxy.org.au" => "fcea528abc269b5768b924db2f33e138",
    "https://galaxy-aust-dev.genome.edu.au" => "71301d49293d949d89db92bd83978591",
    "https://galaxy-aust-staging.genome.edu.au" => "fcea528abc269b5768b924db2f33e138"
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
