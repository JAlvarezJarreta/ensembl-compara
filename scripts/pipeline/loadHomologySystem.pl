#!/usr/local/ensembl/bin/perl -w

use strict;
use DBI;
use Getopt::Long;
use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Compara::GenomeDB;
use Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Pipeline::Analysis;
use Bio::EnsEMBL::Pipeline::Rule;
use Bio::EnsEMBL::Hive::DBSQL::DataflowRuleAdaptor;
use Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor;
use Bio::EnsEMBL::DBLoader;


my $conf_file;
my %analysis_template;
my @speciesList = ();
my %hive_params ;

my %compara_conf = ();
#$compara_conf{'-user'} = 'ensadmin';
$compara_conf{'-port'} = 3306;

my ($help, $host, $user, $pass, $dbname, $port, $compara_conf, $adaptor);
my ($subset_id, $genome_db_id, $prefix, $fastadir, $verbose);

GetOptions('help'     => \$help,
           'conf=s'   => \$conf_file,
           'dbhost=s' => \$host,
           'dbport=i' => \$port,
           'dbuser=s' => \$user,
           'dbpass=s' => \$pass,
           'dbname=s' => \$dbname,
           'v' => \$verbose,
          );

if ($help) { usage(); }

parse_conf($conf_file);

if($host)   { $compara_conf{'-host'}   = $host; }
if($port)   { $compara_conf{'-port'}   = $port; }
if($dbname) { $compara_conf{'-dbname'} = $dbname; }
if($user)   { $compara_conf{'-user'}   = $user; }
if($pass)   { $compara_conf{'-pass'}   = $pass; }


unless(defined($compara_conf{'-host'}) and defined($compara_conf{'-user'}) and defined($compara_conf{'-dbname'})) {
  print "\nERROR : must specify host, user, and database to connect to compara\n\n";
  usage(); 
}

if(%analysis_template and (not(-d $analysis_template{'fasta_dir'}))) {
  die("\nERROR!!\n  ". $analysis_template{'fasta_dir'} . " fasta_dir doesn't exist, can't configure\n");
}

# ok this is a hack, but I'm going to pretend I've got an object here
# by creating a blessed hash ref and passing it around like an object
# this is to avoid using global variables in functions, and to consolidate
# the globals into a nice '$self' package
my $self = bless {};

$self->{'comparaDBA'}   = new Bio::EnsEMBL::Compara::DBSQL::DBAdaptor(%compara_conf);
$self->{'hiveDBA'}      = new Bio::EnsEMBL::Hive::DBSQL::DBAdaptor(-DBCONN => $self->{'comparaDBA'});
#$self->{'pipelineDBA'} = new Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor(-DBCONN => $self->{'comparaDBA'});

if(%hive_params) {
  if(defined($hive_params{'hive_output_dir'})) {
    die("\nERROR!! hive_output_dir doesn't exist, can't configure\n  ", $hive_params{'hive_output_dir'} , "\n")
      unless(-d $hive_params{'hive_output_dir'});
    $self->{'comparaDBA'}->get_MetaContainer->store_key_value('hive_output_dir', $hive_params{'hive_output_dir'});
  }
}


my $analysis = $self->prepareGenomeAnalysis();

exit(0);


#######################
#
# subroutines
#
#######################

sub usage {
  print "loadHomologySystem.pl [options]\n";
  print "  -help                  : print this help\n";
  print "  -conf <path>           : config file describing compara, templates\n";
  print "loadHomologySystem.pl v1.0\n";
  
  exit(1);  
}


sub parse_conf {
  my($conf_file) = shift;

  if($conf_file and (-e $conf_file)) {
    #read configuration file from disk
    my @conf_list = @{do $conf_file};

    foreach my $confPtr (@conf_list) {
      print("HANDLE type " . $confPtr->{TYPE} . "\n") if($verbose);
      if($confPtr->{TYPE} eq 'COMPARA') {
        %compara_conf = %{$confPtr};
      }
      if($confPtr->{TYPE} eq 'BLAST_TEMPLATE') {
        %analysis_template = %{$confPtr};
      }
      if($confPtr->{TYPE} eq 'HIVE') {
        %hive_params = %{$confPtr};
      }
    }
  }
}


#
# need to make sure analysis 'SubmitGenome' is in database
# this is a generic analysis of type 'genome_db_id'
# the input_id for this analysis will be a genome_db_id
# the full information to access the genome will be in the compara database
# also creates 'GenomeLoadMembers' analysis and
# 'GenomeDumpFasta' analysis in the 'genome_db_id' chain
sub prepareGenomeAnalysis
{
  #yes this should be done with a config file and a loop, but...
  my $self = shift;

  my $dataflowRuleDBA = $self->{'hiveDBA'}->get_DataflowRuleAdaptor;
  my $ctrlRuleDBA = $self->{'hiveDBA'}->get_AnalysisCtrlRuleAdaptor;
  my $analysisStatsDBA = $self->{'hiveDBA'}->get_AnalysisStatsAdaptor;
  my $stats;

  #
  # SubmitGenome
  #
  my $submit_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'SubmitGenome',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::Dummy'
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($submit_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($submit_analysis->dbID);
  $stats->batch_size(7000);
  $stats->hive_capacity(-1);
  $stats->update();

  return $submit_analysis
    unless($analysis_template{fasta_dir});

  #
  # GenomeLoadMembers
  #
  my $load_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'GenomeLoadMembers',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::GenomeLoadMembers'
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($load_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($load_analysis->dbID);
  $stats->batch_size(1);
  $stats->hive_capacity(-1); #unlimited
  $stats->update();

  $dataflowRuleDBA->create_rule($submit_analysis, $load_analysis);

  if(defined($self->{'pipelineDBA'})) {
    my $rule = Bio::EnsEMBL::Pipeline::Rule->new('-goalAnalysis'=>$load_analysis);
    $rule->add_condition($submit_analysis->logic_name());
    unless(checkIfRuleExists($self->{'pipelineDBA'}, $rule)) {
      $self->{'pipelineDBA'}->get_RuleAdaptor->store($rule);
    }
  }

  #
  # GenomeSubmitPep
  #
  my $submitpep_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'GenomeSubmitPep',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::GenomeSubmitPep'
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($submitpep_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($submitpep_analysis->dbID);
  $stats->batch_size(1);
  $stats->hive_capacity(3);
  $stats->update();

  $dataflowRuleDBA->create_rule($load_analysis, $submitpep_analysis);

  if(defined($self->{'pipelineDBA'})) {
    my $rule = Bio::EnsEMBL::Pipeline::Rule->new('-goalAnalysis'=>$submitpep_analysis);
    $rule->add_condition($load_analysis->logic_name());
    unless(checkIfRuleExists($self->{'pipelineDBA'}, $rule)) {
      $self->{'pipelineDBA'}->get_RuleAdaptor->store($rule);
    }
  }

  #
  # GenomeDumpFasta
  #
  my $dumpfasta_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'GenomeDumpFasta',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::GenomeDumpFasta',
      -parameters      => 'fasta_dir=>'.$analysis_template{fasta_dir}.',',
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($dumpfasta_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($dumpfasta_analysis->dbID);
  $stats->batch_size(1);
  $stats->hive_capacity(3);
  $stats->update();

  $dataflowRuleDBA->create_rule($load_analysis, $dumpfasta_analysis);

  if(defined($self->{'pipelineDBA'})) {
    my $rule = Bio::EnsEMBL::Pipeline::Rule->new('-goalAnalysis'=>$dumpfasta_analysis);
    $rule->add_condition($load_analysis->logic_name());
    unless(checkIfRuleExists($self->{'pipelineDBA'}, $rule)) {
      $self->{'pipelineDBA'}->get_RuleAdaptor->store($rule);
    }
  }

  #
  # GenomeCalcStats
  #
  my $calcstats_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'GenomeCalcStats',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::GenomeCalcStats',
      -parameters      => '',
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($calcstats_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($calcstats_analysis->dbID);
  $stats->batch_size(1);
  $stats->hive_capacity(3);
  $stats->update();

  $dataflowRuleDBA->create_rule($load_analysis, $calcstats_analysis);

  if(defined($self->{'pipelineDBA'})) {
    my $rule = Bio::EnsEMBL::Pipeline::Rule->new('-goalAnalysis'=>$calcstats_analysis);
    $rule->add_condition($load_analysis->logic_name());
    unless(checkIfRuleExists($self->{'pipelineDBA'}, $rule)) {
      $self->{'pipelineDBA'}->get_RuleAdaptor->store($rule);
    }
  }

  #
  # CreateBlastRules
  #
  my $blastrules_analysis = Bio::EnsEMBL::Pipeline::Analysis->new(
      -db_version      => '1',
      -logic_name      => 'CreateBlastRules',
      -input_id_type   => 'genome_db_id',
      -module          => 'Bio::EnsEMBL::Compara::RunnableDB::CreateBlastRules',
      -parameters      => '{allToAll=>1}',
    );
  $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($blastrules_analysis);
  $stats = $analysisStatsDBA->fetch_by_analysis_id($blastrules_analysis->dbID);
  $stats->batch_size(1);
  $stats->hive_capacity(1);
  $stats->update();

  $dataflowRuleDBA->create_rule($dumpfasta_analysis, $blastrules_analysis);
  $ctrlRuleDBA->create_rule($load_analysis, $blastrules_analysis);
  $ctrlRuleDBA->create_rule($submitpep_analysis, $blastrules_analysis);
  $ctrlRuleDBA->create_rule($dumpfasta_analysis, $blastrules_analysis);

  
  if(defined($self->{'pipelineDBA'})) {
    my $rule = Bio::EnsEMBL::Pipeline::Rule->new('-goalAnalysis'=>$blastrules_analysis);
    $rule->add_condition($dumpfasta_analysis->logic_name());
    unless(checkIfRuleExists($self->{'pipelineDBA'}, $rule)) {
      $self->{'pipelineDBA'}->get_RuleAdaptor->store($rule);
    }
  }
  

  # create an unlinked analysis called blast_template
  # it will not have rule goal/conditions so it will never execute
  my $blast_template = new Bio::EnsEMBL::Pipeline::Analysis(%analysis_template);
  $blast_template->logic_name("blast_template");
  $blast_template->input_id_type('MemberPep');
  eval { $self->{'comparaDBA'}->get_AnalysisAdaptor()->store($blast_template); };

  return $submit_analysis;
}


sub checkIfRuleExists
{
  my $dba = shift;
  my $rule = shift;

  my $conditions = $rule->list_conditions;
  
  my $sql = "SELECT rule_id FROM rule_goal ".
            " WHERE rule_goal.goal='" . $rule->goalAnalysis->dbID."'";
  my $sth = $dba->prepare($sql);
  $sth->execute;

  RULE: while( my($ruleID) = $sth->fetchrow_array ) {
    my $sql = "SELECT condition FROM rule_conditions ".
              " WHERE rule_id='$ruleID'";
    my $sth_cond = $dba->prepare($sql);
    $sth_cond->execute;
    while( my($condition) = $sth_cond->fetchrow_array ) {
      my $foundCondition=0;
      foreach my $qcond (@{$conditions}) {
        if($qcond eq $condition) { $foundCondition=1; }
      }
      unless($foundCondition) { next RULE; }      
    }
    $sth_cond->finish;
    # made through all conditions so this is a match
    print("RULE EXISTS as $ruleID\n");
    return $ruleID;
  }
  $sth->finish;
  return undef;
}


