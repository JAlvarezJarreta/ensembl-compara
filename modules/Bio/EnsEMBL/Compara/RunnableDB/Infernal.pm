#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::Infernal

=cut

=head1 SYNOPSIS

my $db           = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $infernal = Bio::EnsEMBL::Compara::RunnableDB::Infernal->new
  (
   -db         => $db,
   -input_id   => $input_id,
   -analysis   => $analysis
  );
$infernal->fetch_input(); #reads from DB
$infernal->run();
$infernal->output();
$infernal->write_output(); #writes to DB

=cut


=head1 DESCRIPTION

This Analysis will take the sequences from a cluster, the cm from
nc_profile and run a profiled alignment, storing the results as
cigar_lines for each sequence.

=cut


=head1 CONTACT

  Contact Albert Vilella on module implementation/design detail: avilella@ebi.ac.uk
  Contact Ewan Birney on EnsEMBL in general: birney@sanger.ac.uk

=cut


=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut


package Bio::EnsEMBL::Compara::RunnableDB::Infernal;

use strict;
use Getopt::Long;
use POSIX qw(ceil floor);
use Time::HiRes qw(time gettimeofday tv_interval);

use Bio::AlignIO;
use Bio::EnsEMBL::BaseAlignFeature;
use Bio::EnsEMBL::Compara::Member;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data for repeatmasker from the database
    Returns :   none
    Args    :   none

=cut


sub fetch_input {
  my( $self) = @_;

  $self->throw("No input_id") unless defined($self->input_id);

  $self->{'infernal_starttime'} = time()*1000;
  $self->{'method'} = 'Infernal';

  $self->{memberDBA} = $self->compara_dba->get_MemberAdaptor;
  $self->{treeDBA} = $self->compara_dba->get_NCTreeAdaptor;

  $self->get_params($self->parameters);
  $self->get_params($self->input_id);

  # Fetch sequences
  $self->{'input_fasta'} = $self->dump_sequences_to_workdir($self->{'nc_tree'});

# For long parameters, look at analysis_data
  if($self->{analysis_data_id}) {
    my $analysis_data_id = $self->{analysis_data_id};
    my $analysis_data_params = $self->db->get_AnalysisDataAdaptor->fetch_by_dbID($analysis_data_id);
    $self->get_params($analysis_data_params);
  }

  return 1;
}


sub get_params {
  my $self         = shift;
  my $param_string = shift;

  return if ($param_string eq "1");

  return unless($param_string);
  print("parsing parameter string : ",$param_string,"\n");

  my $params = eval($param_string);
  return unless($params);

  foreach my $key (keys %$params) {
    print("  $key : ", $params->{$key}, "\n");
  }

  print("parameters...\n");
  if (defined $params->{'max_gene_count'}) {
    $self->{'max_gene_count'} = $params->{'max_gene_count'};
    printf("  max_gene_count : %d\n", $self->{'max_gene_count'});
  }
  if(defined($params->{'nc_tree_id'})) {
    $self->{'nc_tree'} = 
         $self->compara_dba->get_NCTreeAdaptor->
         fetch_node_by_node_id($params->{'nc_tree_id'});
    printf("  nc_tree_id : %d\n", $self->{'nc_tree_id'});
  }
  if(defined($params->{'clusterset_id'})) {
    $self->{'clusterset_id'} = $params->{'clusterset_id'};
    printf("  clusterset_id : %d\n", $self->{'clusterset_id'});
  }
  if(defined($params->{'cmbuild_exe'})) {
    $self->{'cmbuild_exe'} = $params->{'cmbuild_exe'};
    printf("  cmbuild_exe : %d\n", $self->{'cmbuild_exe'});
  }

  return;
}


=head2 run

    Title   :   run
    Usage   :   $self->run
    Function:   runs hmmbuild
    Returns :   none
    Args    :   none

=cut

sub run {
  my $self = shift;

  return if (defined($self->{single_peptide_tree}));
  $self->run_infernal;
}


=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output
    Function:   stores nctree
    Returns :   none
    Args    :   none

=cut


sub write_output {
  my $self = shift;
  $self->parse_and_store_alignment_into_tree;
  $self->_store_aln_tags;
}


##########################################
#
# internal methods
#
##########################################

1;

sub dump_sequences_to_workdir {
  my $self = shift;
  my $cluster = shift;

  my $fastafile = $self->worker_temp_directory . "cluster_" . $cluster->node_id . ".fasta";
  print("fastafile = '$fastafile'\n") if($self->debug);

  my $seq_id_hash;
  my $residues = 0;
  print "fetching sequences...\n" if ($self->debug);

  my $node_id = $cluster->node_id;
  my $member_list = $cluster->get_all_leaves;
  if (2 > scalar @$member_list) {
    warn("Only one member for cluster [$node_id]");
    return 1;
  }
  print STDERR "Counting number of members\n" if ($self->debug);
  $self->{'tag_gene_count'} = scalar(@{$member_list});

  open(OUTSEQ, ">$fastafile")
    or $self->throw("Error opening $fastafile for write!");
  my $count = 0;
  foreach my $member (@{$member_list}) {
    my $sequence_id;
    eval {$sequence_id = $member->sequence_id;};
    if ($@) {
      $DB::single=1;1;
    }
    next if($seq_id_hash->{$sequence_id});
    my $description;
    eval { $description = $member->description; };
    unless (defined($description) && $description =~ /Acc\:(\w+)/) {
      warn ("No accession for [$description]");
    }
    $seq_id_hash->{$sequence_id} = 1;
    $count++;
    my $member_model_id = $1;
    $self->{model_id_hash}{$member_model_id} = 1;

    my $seq = $member->sequence;
    $residues += $member->seq_length;
    $seq =~ s/(.{72})/$1\n/g;
    chomp $seq;
    print STDERR $member->sequence_id. "\n" if ($self->debug);
    print OUTSEQ ">". $member->sequence_id. "\n$seq\n";
    print STDERR "sequences $count\n" if ($count % 50 == 0);
  }
  close(OUTSEQ);

  if(scalar keys (%{$seq_id_hash}) <= 1) {
    $self->update_single_peptide_tree($cluster);
    $self->{single_peptide_tree} = 1;
  }

  $self->{'tag_residue_count'} = $residues;
  my $this_hash_count = scalar keys %$seq_id_hash; my $this_gene_count = $self->{'tag_gene_count'};
  my $perc_unique = ($this_hash_count / $this_gene_count) * 100;
  print "tag_gene_count ", $self->{'tag_gene_count'}, "\n";
  print "Percent unique sequences: $perc_unique ($this_hash_count / $this_gene_count)\n" if ($self->debug);

  return $fastafile;
}

sub update_single_peptide_tree
{
  my $self   = shift;
  my $tree   = shift;

  foreach my $member (@{$tree->get_all_leaves}) {
    next unless($member->isa('Bio::EnsEMBL::Compara::AlignedMember'));
    next unless($member->sequence);
    $DB::single=1;1;
    $member->cigar_line(length($member->sequence)."M");
    $self->compara_dba->get_NCTreeAdaptor->store($member);
    printf("single_pepide_tree %s : %s\n", $member->stable_id, $member->cigar_line) if($self->debug);
  }
}


sub run_infernal {
  my $self = shift;

  return if (1 == $self->{single_peptide_tree});
  my $input_fasta = $self->{'input_fasta'};

  my $stk_output = $self->worker_temp_directory . "output.stk";

  my $infernal_executable = $self->analysis->program_file;
    unless (-e $infernal_executable) {
      print "Using default cmalign executable!\n";
      $infernal_executable = "/nfs/users/nfs_a/avilella/src/infernal/infernal-1.0/src/cmalign";
  }
  $self->throw("can't find a cmalign executable to run\n") unless(-e $infernal_executable);

  if (1 < scalar keys %{$self->{model_id_hash}}) {
    # We revert to the clustering_id tag, which maps to the RFAM
    # 'name' field in nc_profile (e.g. 'mir-135' instead of 'RF00246')
    print STDERR "WARNING: More than one model: ", join(",",keys %{$self->{model_id_hash}}), "\n";
    $self->{model_id} = $self->{nc_tree}->get_tagvalue('clustering_id');
    # $self->throw("This cluster has more than one associated model");
  } else {
    my @models = keys %{$self->{model_id_hash}};
    $self->{model_id} = $models[0];
  }

  my $ret1 = $self->dump_model('model_id',$self->{model_id});
  my $ret2 = $self->dump_model('name',$self->{model_id}) if (1 == $ret1);
  if (1 == $ret2) {
    $self->{'nc_tree'}->release_tree;
    $self->{'nc_tree'} = undef;
    $self->input_job->transient_error(0);
    die;
  }

  my $cmd = $infernal_executable;
  # infernal -o cluster_6357.stk RF00599_profile.cm cluster_6357.fasta

  $cmd .= " --mxsize 4000 " if($self->input_job->retry_count >= 1); # large alignments FIXME separate Infernal_huge
  $cmd .= " -o " . $stk_output;
  $cmd .= " " . $self->{profile_file};
  $cmd .= " " . $self->{input_fasta};

  $self->compara_dba->dbc->disconnect_when_inactive(1);
  print("$cmd\n") if($self->debug);
  $DB::single=1;1;
  unless(system($cmd) == 0) {
    $self->throw("error running infernal, $!\n");
  }
  $self->compara_dba->dbc->disconnect_when_inactive(0);

  # cmbuild --refine the alignment
  ######################
  # Attempt to refine the alignment before building the CM using
  # expectation-maximization (EM). A CM is first built from the
  # initial alignment as usual. Then, the sequences in the alignment
  # are realigned optimally (with the HMM banded CYK algorithm,
  # optimal means optimal given the bands) to the CM, and a new CM is
  # built from the resulting alignment. The sequences are then
  # realigned to the new CM, and a new CM is built from that
  # alignment. This is continued until convergence, specifically when
  # the alignments for two successive iterations are not significantly
  # different (the summed bit scores of all the sequences in the
  # alignment changes less than 1% be- tween two successive
  # iterations). The final alignment (the alignment used to build the
  # CM that gets written to cmfile) is written to <f>.

  my $cmbuild_exe = $self->{cmbuild_exe} || "/nfs/users/nfs_a/avilella/src/infernal/infernal-1.0/src/cmbuild";
  # cmbuild --refine output.stk.new -F mir-32_profile.cm.new output.stk
  my $refined_stk_output = $stk_output . ".refined";
  my $refined_profile = $self->{profile_file} . ".refined";
  $cmd = $cmbuild_exe;
  $cmd .= " --refine $refined_stk_output";
  $cmd .= " -F $refined_profile";
  $cmd .= " $stk_output";
  $self->compara_dba->dbc->disconnect_when_inactive(1);
  print("$cmd\n") if($self->debug);
  $DB::single=1;1;
  unless(system($cmd) == 0) {
    $self->throw("error running cmbuild refine, $!\n");
  }
  $self->compara_dba->dbc->disconnect_when_inactive(0);

  $self->{stk_output} = $refined_stk_output;
  # Reformat with sreformat
  my $fasta_output = $self->worker_temp_directory . "output.fasta";
  my $cmd = "/usr/local/ensembl/bin/sreformat a2m $refined_stk_output > $fasta_output";
  unless( system("$cmd") == 0) {
    print("$cmd\n");
    $self->throw("error running sreformat, $!\n");
  }

  $self->{infernal_output} = $fasta_output;

  return 0;
}

sub dump_model {
  my $self = shift;
  my $field = shift;
  my $model_id = shift;

  my $sql = 
    "SELECT hc_profile FROM nc_profile ".
      "WHERE $field=\"$model_id\"";
  my $sth = $self->compara_dba->dbc->prepare($sql);
  $sth->execute();
  my $nc_profile  = $sth->fetchrow;
  unless (defined($nc_profile)) {
    return 1;
  }
  my $profile_file = $self->worker_temp_directory . $model_id . "_profile.cm";
  open FILE, ">$profile_file" or die "$!";
  print FILE $nc_profile;
  close FILE;

  $self->{profile_file} = $profile_file;
  return 0;
}

sub parse_and_store_alignment_into_tree
{
  my $self = shift;
  my $infernal_output =  $self->{infernal_output};
  my $tree = $self->{'nc_tree'};

  return unless($infernal_output);

  #
  # parse SS_cons lines and store into nc_tree_tag
  #

  my $stk_output = $self->{stk_output};
  open (STKFILE, $stk_output) or $self->throw("Couldnt open STK file [$stk_output]");
  my $ss_cons_string = '';
  while(<STKFILE>) {
    next unless ($_ =~ /SS_cons/);
    my $line = $_;
    $line =~ /\#=GC\s+SS_cons\s+(\S+)\n/;
    $self->throw("Malformed SS_cons line") unless (defined($1));
    $ss_cons_string .= $1;
  }
  close(STKFILE);
  $self->{'nc_tree'}->store_tag('ss_cons', $ss_cons_string);

  #
  # parse alignment file into hash: combine alignment lines
  #
  my %align_hash;

  # fasta format
  my $aln_io = Bio::AlignIO->new
    (-file => "$infernal_output",
     -format => 'fasta');
  my $aln = $aln_io->next_aln;
  foreach my $seq ($aln->each_seq) {
    $align_hash{$seq->display_id} = $seq->seq;
  }
  $aln_io->close;

  #
  # convert alignment string into a cigar_line
  #

  my $alignment_length;
  foreach my $id (keys %align_hash) {
    my $alignment_string = $align_hash{$id};
    unless (defined $alignment_length) {
      $alignment_length = length($alignment_string);
    } else {
      if ($alignment_length != length($alignment_string)) {
        $self->throw("While parsing the alignment, some id did not return the expected alignment length\n");
      }
    }

    # From the Infernal UserGuide:
    # ###########################
    # In the aligned sequences, a '.' character indicates an inserted column
    # relative to consensus; the '.' character is an alignment pad. A '-'
    # character is a deletion relative to consensus.  The symbols in the
    # consensus secondary structure annotation line have the same meaning
    # that they did in a pairwise alignment from cmsearch. The #=GC RF line
    # is reference annotation. Non-gap characters in this line mark
    # consensus columns; cmalign uses the residues of the consensus sequence
    # here, with UPPER CASE denoting STRONGLY CONSERVED RESIDUES, and LOWER
    # CASE denoting WEAKLY CONSERVED RESIDUES. Gap characters (specifically,
    # the '.' pads) mark insertions relative to consensus. As described below,
    # cmbuild is capable of reading these RF lines, so you can specify which
    # columns are consensus and which are inserts (otherwise, cmbuild makes
    # an automated guess, based on the frequency of gaps in each column)
    $alignment_string =~ s/\./\-/g;            # Infernal returns dots even though they are gaps
    $alignment_string = uc($alignment_string); # Infernal can lower-case regions
    $alignment_string =~ s/\-([A-Z])/\- $1/g;
    $alignment_string =~ s/([A-Z])\-/$1 \-/g;

    my @cigar_segments = split " ",$alignment_string;

    my $cigar_line = "";
    foreach my $segment (@cigar_segments) {
      my $seglength = length($segment);
      $seglength = "" if ($seglength == 1);
      if ($segment =~ /^\-+$/) {
        $cigar_line .= $seglength . "D";
      } else {
        $cigar_line .= $seglength . "M";
      }
    }
    $align_hash{$id} = $cigar_line;
  }

  #
  # align cigar_line to member and store
  #
  foreach my $member (@{$tree->get_all_leaves}) {
    if ($align_hash{$member->sequence_id} eq "") {
      $self->throw("infernal produced an empty cigar_line for ".$member->stable_id."\n");
    }
    $DB::single=1;1;
    $member->cigar_line($align_hash{$member->sequence_id});
    ## Check that the cigar length (Ms) matches the sequence length
    my @cigar_match_lengths = map { if ($_ eq '') {$_ = 1} else {$_ = $_;} } map { $_ =~ /^(\d*)/ } ( $member->cigar_line =~ /(\d*[M])/g );
    my $seq_cigar_length; map { $seq_cigar_length += $_ } @cigar_match_lengths;
    my $member_sequence = $member->sequence; $member_sequence =~ s/\*//g;
    if ($seq_cigar_length != length($member_sequence)) {
      $self->throw("While storing the cigar line, the returned cigar length did not match the sequence length\n");
    }
    #
    printf("update nc_tree_member %s : %s\n",$member->stable_id, $member->cigar_line) if($self->debug);
    $self->compara_dba->get_NCTreeAdaptor->store($member);
  }

  return undef;
}

sub _store_aln_tags {
    my $self = shift;
    my $tree = $self->{'nc_tree'};
    return unless($tree);

    my $pta = $self->compara_dba->get_NCTreeAdaptor;

    print "Storing Alignment tags...\n";
    my $sa = $tree->get_SimpleAlign;
    $DB::single=1;1;
    # Model id
    $tree->store_tag("model_id",$self->{model_id});

    # Alignment percent identity.
    my $aln_pi = $sa->average_percentage_identity;
    $tree->store_tag("aln_percent_identity",$aln_pi);

    # Alignment length.
    my $aln_length = $sa->length;
    $tree->store_tag("aln_length",$aln_length);

    # Alignment runtime.
    my $aln_runtime = int(time()*1000-$self->{'infernal_starttime'});
    $tree->store_tag("aln_runtime",$aln_runtime);

    # Alignment method.
    my $aln_method = $self->{'method'};
    $tree->store_tag("aln_method",$aln_method);

    # Alignment residue count.
    my $aln_num_residues = $sa->no_residues;
    $tree->store_tag("aln_num_residues",$aln_num_residues);

    return undef;
}


1;
