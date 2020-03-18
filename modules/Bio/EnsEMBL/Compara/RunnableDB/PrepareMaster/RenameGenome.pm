=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2020] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::PrepareMaster::RenameGenome

=head1 DESCRIPTION

Renames genome in master and previous databases, as well as in mlss config file, species tree file and genome
dumps. Files that will stop working due to the renaming and cannot be modified, i.e. exonerate and sketch
files, are deleted so they are properly regenerated by their corresponding pipeline.

=over

=item old_name

Mandatory. Old genome (species) name.

=item new_name

Mandatory. New genome (species) name.

=item master_db

Mandatory. Alias of the compara master database.

=item prev_dbs

Mandatory. Alias(es) or alias pattern(s) of previous databases to be renamed as well.

=item xml_file

Mandatory. Path to the MLSS configuration XML file.

=item genome_dumps_dir

Mandatory. Path to the root folder where the genome dumps are stored.

=item sketch_dir

Mandatory. Path to the root folder where the sketch files are stored.

=item species_tree

Optional. Path to the species tree file.

=back

=head1 EXAMPLES

    standaloneJob.pl Bio::EnsEMBL::Compara::RunnableDB::PrepareMaster::RenameGenome \
        -compara_db $(mysql-ens-compara-prod-10-ensadmin details url jalvarez_prep_citest_master_for_rel_100) \
        -old_name canis_familiaris -new_name perricus_bonicus -master_db compara_master -prev_dbs '*_prev' \
        -xml_file $ENSEMBL_CVS_ROOT_DIR/ensembl-compara/conf/citest/mlss_conf.xml \
        -genome_dumps_dir /hps/nobackup2/production/ensembl/jalvarez/genome_dumps/ \
        -sketch_dir /hps/nobackup2/production/ensembl/jalvarez/species_tree/citest_sketches/ \
        -species_tree $ENSEMBL_CVS_ROOT_DIR/ensembl-compara/conf/citest/species_tree.branch_len.nw

=cut

package Bio::EnsEMBL::Compara::RunnableDB::PrepareMaster::RenameGenome;

use warnings;
use strict;

use File::Basename;

use Bio::EnsEMBL::Hive::Utils;
use Bio::EnsEMBL::Registry;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


sub fetch_input {
    my $self = shift;

    # Get all the required compara DBAdaptors
    my $db_list = $self->param_required('prev_dbs');
    $db_list = [$db_list] unless ref($db_list);
    push @{$db_list}, $self->param_required('master_db');
    my %dba_hash = $self->get_all_compara_dbas($db_list);
    $self->param('dba_hash', \%dba_hash);
}


sub run {
    my $self = shift;

    my $old_name = $self->param_required('old_name');
    my $new_name = $self->param_required('new_name');
    my $xml_file = $self->param_required('xml_file');
    my $genome_dumps_dir = $self->param_required('genome_dumps_dir');
    my $sketch_dir = $self->param_required('sketch_dir');
    my $species_tree = $self->param('species_tree');

    my $master_db = $self->param('master_db');
    my $dba_hash = $self->param('dba_hash');
    my $genome_db = $dba_hash->{$master_db}->get_GenomeDBAdaptor()->fetch_by_registry_name($old_name);

    # We really need a transaction to ensure we are not screwing the databases
    foreach my $dba (values %{$dba_hash}) {
        # Make sure we are ensadmin for every connection
        $self->elevate_privileges($dba->dbc);
        $dba->dbc->sql_helper->transaction(-CALLBACK => sub {
            $dba->dbc->do("UPDATE genome_db SET name = '$new_name' WHERE name = '$old_name' AND first_release IS NOT NULL AND last_release IS NULL");
            $dba->dbc->do("UPDATE method_link_species_set_tag SET value = '$new_name' WHERE tag LIKE '%reference_species' AND value = '$old_name'");
            print "Species '$old_name' renamed to '$new_name' in ", $dba->dbc->dbname, "\n" if $self->debug;
        });
    }

    # Rename the genome in the mlss_conf.xml and species tree files
    my $content = $self->_slurp($xml_file);
    $content =~ s/"$old_name"/"$new_name"/;
    $self->_spurt($xml_file, $content);
    print "\nUpdated content of $xml_file\n" if $self->debug;
    if (defined $species_tree) {
        $content = $self->_slurp($species_tree);
        $content =~ s/([\(\),:])$old_name([\(\),:])/$1$new_name$2/;
        $self->_spurt($species_tree, $content);
        print "Updated content of $species_tree\n" if $self->debug;
    }

    my $dumps_path = dirname($genome_db->_get_genome_dump_path());
    # Rename *.fa and *.fai files
    my @fasta_files = glob qq(${dumps_path}/${old_name}.*.fa ${dumps_path}/${old_name}.*.fai);
    foreach my $file (@fasta_files) {
        (my $new_fname = $file) =~ s/$old_name/$new_name/;
        rename $file, $new_fname;
    }
    print "\nFiles renamed:\n", join("\n", @fasta_files), "\n" if $self->debug;
    # Exonerate and sketch files cannot be renamed: they need to be regenerated with the updated name
    my @files_to_rm = glob qq(${dumps_path}/${old_name}.*.es?);
    push @files_to_rm, glob qq(${sketch_dir}/${old_name}.*);
    # Delete also every collection sketch file related with the renamed genome
    my $ssa = $dba_hash->{$master_db}->get_SpeciesSetAdaptor();
    my @collections = grep { $_->size > 2 } @{ $ssa->fetch_all_by_GenomeDB($genome_db) };
    foreach my $set ( @collections ) {
        # Match and delete both "collection-<name>.*" and "<name>.*" files (using "*<name>.*")
        (my $set_name = $set->name) =~ s/collection-/*/;
        push @files_to_rm, glob qq(${sketch_dir}/${set_name}.*);
    }
    unlink @files_to_rm;
    print "\nFiles removed:\n" . join("\n", @files_to_rm) . "\n" if $self->debug;
}


1;
