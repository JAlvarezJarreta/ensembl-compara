# See the NOTICE file distributed with this work for additional information
# regarding copyright ownership.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

use File::Spec;
use Test::More;

use Bio::EnsEMBL::Compara::Utils::Test;

sub is_valid_json {
    my $filename = shift;

    my @command = ('python', '-m', 'json.tool', $filename, File::Spec->devnull());
    Bio::EnsEMBL::Compara::Utils::Test::test_command(\@command, "$filename is a valid JSON file");
}

my @all_files = Bio::EnsEMBL::Compara::Utils::Test::find_all_files();

foreach my $f (@all_files) {
    if ($f =~ /\.json$/) {
        is_valid_json($f);
    }
}

done_testing();

