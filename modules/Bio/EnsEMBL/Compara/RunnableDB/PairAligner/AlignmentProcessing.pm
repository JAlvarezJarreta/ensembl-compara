=head1 LICENSE

See the NOTICE file distributed with this work for additional information
regarding copyright ownership.

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

Bio::EnsEMBL::Compara::RunnableDB::PairAligner::AlignmentProcessing

=head1 DESCRIPTION

Abstract base class of AlignmentChains and AlignmentNets

=cut

package Bio::EnsEMBL::Compara::RunnableDB::PairAligner::AlignmentProcessing;

use strict;
use warnings;

use List::Util qw(sum);

use Bio::EnsEMBL::Utils::Exception qw(throw);

use Bio::EnsEMBL::Compara::GenomicAlignBlock;
use Bio::EnsEMBL::Compara::Utils::IDGenerator qw(:all);

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


sub fetch_input {
    my ($self) = @_;
    
    $self->param('query_DnaFrag_hash', {});
    $self->param('target_DnaFrag_hash', {});
}


=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output()
    Function:   Writes contents of $self->param('chains') into $self->compara_dba
    Returns :   1
    Args    :   None

=cut

sub write_output {
  my($self) = @_;

  $self->assign_ids;

  foreach my $chain (@{ $self->param('chains') }) {
      $self->_write_output($chain);
    }

  return 1;

}

sub _write_output {
    my ($self, $chain) = @_;
    
        my $group_id;
        
        #store first block
        my $first_block = shift @$chain;
        $self->compara_dba->get_GenomicAlignBlockAdaptor->store($first_block);
        
        #Set the group_id if one doesn't already exist ie for chains, to be the
        #dbID of the first genomic_align_block. For nets,the group_id has already
        #been set and is the same as it's chain.
        unless (defined($first_block->group_id)) {
            $group_id = $first_block->dbID;
            $self->compara_dba->get_GenomicAlignBlockAdaptor->store_group_id($first_block, $group_id);
        }
        
        #store the rest of the genomic_align_blocks
        foreach my $block (@$chain) {
            if (defined $group_id) {
                $block->group_id($group_id);
            }
            $self->compara_dba->get_GenomicAlignBlockAdaptor->store($block);
        }
}

###########################################
# chain sorting
###########################################
sub sort_chains_by_max_block_score {
  my ($self, $chains) = @_;

  # sort the chains by maximum score
  my @chain_hashes;
  foreach my $chain (@$chains) {
    my $chain_hash = { chain => $chain };
    foreach my $block (@$chain) {
      if (not exists $chain_hash->{qname}) {
        $chain_hash->{qname} = $block->seqname;
        $chain_hash->{tname} = $block->hseqname;
      }
      if (not exists $chain_hash->{score} or
          $block->score > $chain_hash->{score}) {
        $chain_hash->{score} = $block->score;
      }
    }
    push @chain_hashes, $chain_hash;
  }
  
  my @sorted = map { $_->{chain}} sort {
    $b->{score} <=> $a->{score} 
    or $a->{qname} cmp $b->{qname}
    or $a->{tname} cmp $b->{tname}
  } @chain_hashes;

  return \@sorted;
}


###########################################
# feature splitting
###########################################
sub split_feature {
  my ($self, $f, $max_gap) = @_;

  my @split_dafs;
  
  my $need_to_split = 0;

  my @pieces = split(/(\d*[MDI])/, $f->cigar_string);
  foreach my $piece ( @pieces ) {
    next if ($piece !~ /^(\d*)([MDI])$/);
    my $num = ($1 or 1);
    my $type = $2;

    if (($type eq "I" or $type eq "D") and $num >= $max_gap) {
      $need_to_split = 1;
      last;
    }
  }
  
  if ($need_to_split) {
    my (@new_feats);
    foreach my $ug (sort {$a->start <=> $b->start} $f->ungapped_features) {
      if (@new_feats) {
        my ($dist, $hdist);

        my $last_ug = $new_feats[-1]->[-1];

        if ($ug->end < $last_ug->start) {
          # blocks in reverse orienation
          $dist = $last_ug->start - $ug->end - 1;
        } else {
          # blocks in forward orienatation
          $dist = $ug->start - $last_ug->end - 1;
        }
        if ($ug->hend < $last_ug->hstart) {
          # blocks in reverse orienation
          $hdist = $last_ug->hstart - $ug->hend - 1;
        } else {
          # blocks in forward orienatation
          $hdist = $ug->hstart - $last_ug->hend - 1;
        }

        if ($dist >= $max_gap or $hdist >= $max_gap) {
          push @new_feats, [];
        }
      } else {
        push @new_feats, [];
      }
      push @{$new_feats[-1]}, $ug;
    }
    
    foreach my $mini_list (@new_feats) {
      push @split_dafs, Bio::EnsEMBL::DnaDnaAlignFeature->new(-features => $mini_list, -align_type => 'ensembl');
    }

  } else {
    @split_dafs = ($f)
  }  

  return @split_dafs;
}

############################################
# cigar conversion
############################################

sub compara_cigars_from_daf_cigar {
  my ($self, $daf_cigar) = @_;

  my ($q_cigar_line, $t_cigar_line, $align_length);

  my @pieces = split(/(\d*[MDI])/, $daf_cigar);

  my ($q_counter, $t_counter) = (0,0);

  foreach my $piece ( @pieces ) {

    next if ($piece !~ /^(\d*)([MDI])$/);
    
    my $num = ($1 or 1);
    my $type = $2;
    
    if( $type eq "M" ) {
      $q_counter += $num;
      $t_counter += $num;
      
    } elsif( $type eq "D" ) {
      $q_cigar_line .= (($q_counter == 1) ? "" : $q_counter)."M";
      $q_counter = 0;
      $q_cigar_line .= (($num == 1) ? "" : $num)."D";
      $t_counter += $num;
      
    } elsif( $type eq "I" ) {
      $q_counter += $num;
      $t_cigar_line .= (($t_counter == 1) ? "" : $t_counter)."M";
      $t_counter = 0;
      $t_cigar_line .= (($num == 1) ? "" : $num)."D";
    }
    $align_length += $num;
  }

  $q_cigar_line .= (($q_counter == 1) ? "" : $q_counter)."M"
      if $q_counter;
  $t_cigar_line .= (($t_counter == 1) ? "" : $t_counter)."M"
      if $t_counter;
  
  return ($q_cigar_line, $t_cigar_line, $align_length);
}


sub daf_cigar_from_compara_cigars {
  my ($self, $q_cigar, $t_cigar) = @_;

  my (@q_pieces, @t_pieces);
  foreach my $piece (split(/(\d*[MDGI])/, $q_cigar)) {
    next if ($piece !~ /^(\d*)([MDGI])$/);

    my $num = $1; $num = 1 if $num eq "";
    my $type = $2; $type = 'D' if $type ne 'M';

    if ($num > 0) {
      push @q_pieces, { num  => $num,
                        type => $type, 
                      };
    }
  }
  foreach my $piece (split(/(\d*[MDGI])/, $t_cigar)) {
    next if ($piece !~ /^(\d*)([MDGI])$/);
    
    my $num = $1; $num = 1 if $num eq "";
    my $type = $2; $type = 'D' if $type ne 'M';

    if ($num > 0) {
      push @t_pieces, { num  => $num,
                        type => $type,
                      };
    }
  }

  my $daf_cigar = "";

  while(@q_pieces and @t_pieces) {
    # should never be left with a q piece and no target pieces, or vice versa
    my $q = shift @q_pieces;
    my $t = shift @t_pieces;

    if ($q->{num} == $t->{num}) {
      if ($q->{type} eq 'M' and $t->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'M';
      } elsif ($q->{type} eq 'M' and $t->{type} eq 'D') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'I';
      } elsif ($q->{type} eq 'D' and $t->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'D';
      } else {
        # must be a delete in both seqs; warn and ignore
        warn("The following cigars have a simultaneous gap:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
    } elsif ($q->{num} > $t->{num}) {
      if ($q->{type} ne 'M') {
        warn("The following cigars are strange:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
      
      if ($t->{type} eq 'M') {
        $daf_cigar .= ($t->{num} > 1 ? $t->{num} : "") . 'M';
      } elsif ($t->{type} eq 'D') {
        $daf_cigar .= ($t->{num} > 1 ? $t->{num} : "") . 'I';
      } 

      unshift @q_pieces, { 
        type => 'M',
        num  => $q->{num} - $t->{num}, 
      };

    } else {
      # $t->{num} > $q->{num}
      if ($t->{type} ne 'M') {
        warn("The following cigars are strange:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
      
      if ($q->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'M';
      } elsif ($q->{type} eq 'D') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'D';
      } 
      unshift @t_pieces, { 
        type => 'M',
        num  => $t->{num} - $q->{num},
      };
    } 
  }

  # final sanity checks

  if (@q_pieces or @t_pieces) {
    warn("Left with dangling pieces in the following cigars:\n" .
          $q_cigar . "\n". 
          $t_cigar . "\n");
    return undef;
  }
  
  my $last_type;
  foreach my $piece (split(/(\d*[MDI])/, $daf_cigar)) {
    next if not $piece;
    my ($type) = ($piece =~ /\d*([MDI])/);

    if (defined $last_type and
       (($last_type eq 'I' and $type eq 'D') or
        ($last_type eq 'D' and $type eq 'I'))) {

      warn("Adjacent Insert/Delete in the following cigars:\n" .
           $q_cigar . "\n". 
           $t_cigar . "\n".
           $daf_cigar . "\n");

      return undef;
    }
    $last_type = $type;
  }
  
  return $daf_cigar;
}


sub convert_output {
  my ($self, $chains_of_dafs, $t_visible) = @_; 

  my (@chains_of_blocks);
  
  $t_visible = 1 if (!defined $t_visible);

  foreach my $chain_of_dafs (@$chains_of_dafs) {
    my @chain_of_blocks;

    foreach my $raw_daf (sort {$a->start <=> $b->start} @$chain_of_dafs) {
      my @split_dafs;
      if ($self->param('max_gap')) {
        @split_dafs = $self->split_feature($raw_daf, $self->param('max_gap'));
      } else {
        @split_dafs = ($raw_daf);
      }

      foreach my $daf (@split_dafs) {
        my ($q_cigar, $t_cigar, $al_len) = 
            $self->compara_cigars_from_daf_cigar($daf->cigar_string);
        
        my $q_dnafrag = $self->param('query_DnaFrag_hash')->{$daf->seqname};
        my $t_dnafrag = $self->param('target_DnaFrag_hash')->{$daf->hseqname};
        
        my $out_mlss = $self->param('output_MethodLinkSpeciesSet');

        my $q_genomic_align = Bio::EnsEMBL::Compara::GenomicAlign->new
            (-dnafrag        => $q_dnafrag,
             -dnafrag_start  => $daf->start,
             -dnafrag_end    => $daf->end,
             -dnafrag_strand => $daf->strand,
             -cigar_line     => $q_cigar,
	     -visible        => 1,      #always set to true
             -method_link_species_set => $out_mlss);
  
        my $t_genomic_align = Bio::EnsEMBL::Compara::GenomicAlign->new
            (-dnafrag        => $t_dnafrag,
             -dnafrag_start  => $daf->hstart,
             -dnafrag_end    => $daf->hend,
             -dnafrag_strand => $daf->hstrand,
             -cigar_line     => $t_cigar,
	     -visible        => $t_visible, #will be false for example, self alignments
             -method_link_species_set => $out_mlss);

        my $gen_al_block = Bio::EnsEMBL::Compara::GenomicAlignBlock->new
            (-genomic_align_array     => [$q_genomic_align, $t_genomic_align],
             -score                   => $daf->score,
             -length                  => $al_len,
             -method_link_species_set => $out_mlss,
	     -group_id                => $daf->group_id,
	     -level_id                => $daf->level_id ? $daf->level_id : 1);
        push @chain_of_blocks, $gen_al_block;
      }
    }

    push @chains_of_blocks, \@chain_of_blocks;
  }
    
  return \@chains_of_blocks;
}

sub cleanse_output {
  my ($self, $chains) = @_;

  # need to "cleanse" the of its original database attachments, so 
  # that it is stored as a fresh blocks. This involves touching the
  # object's privates, but more efficent than creating brand-new
  # blocks from scratch
  # NB don't undef group_id - I want to keep the chain group_id for the net.

  foreach my $chain (@{$chains}) {
    foreach my $gab (@{$chain}) {

      $gab->{'adaptor'} = undef;
      $gab->{'dbID'} = undef;
      $gab->{'method_link_species_set_id'} = undef;
      $gab->method_link_species_set($self->param('output_MethodLinkSpeciesSet'));
      foreach my $ga (@{$gab->get_all_GenomicAligns}) {
        $ga->{'adaptor'} = undef;
        $ga->{'dbID'} = undef;
        $ga->{'method_link_species_set_id'} = undef;
        $ga->method_link_species_set($self->param('output_MethodLinkSpeciesSet'));
      }
    }
  }

}


###################################
# redundant alignment deletion

sub delete_alignments {
  my ($self, $mlss) = @_;

  my $range_info = get_previously_assigned_range(
      $self->compara_dba->dbc,
      'genomic_align_' . $mlss->dbID,
      $self->get_requestor_id,
  );

  # No range already assigned
  return unless $range_info;

  my ($min_id, $n_ids) = @$range_info;

  my $sql_gab = 'DELETE FROM genomic_align_block WHERE genomic_align_block_id BETWEEN ? AND ?';
  my $sql_ga  = 'DELETE FROM genomic_align       WHERE genomic_align_id       BETWEEN ? AND ?';

  my $dbc = $self->compara_dba->dbc;
  $dbc->do($sql_ga,  undef, $min_id, $min_id+$n_ids-1);
  $dbc->do($sql_gab, undef, $min_id, $min_id+$n_ids-1);
}


sub assign_ids {
    my ($self) = @_;

    my $chains      = $self->param('chains');
    my $mlss_id     = $self->param('output_mlss_id');
    my $n_blocks    = sum(map {scalar(@$_)} @$chains);

    # For simplicity, genomic_align_block_id is the genomic_align_id of its
    # first genomic_align. Since all blocks are pairwise, we need to
    # request two values per block only.
    # group_id (for chains) is set to the genomic_align_block_id of the
    # first block of the chain.
    # group_id (for nets) should not be touched, cf the comment in
    # _write_output, because it is already set (coming from chains)
    my $ga_id = get_id_range(
        $self->compara_dba->dbc,
        "genomic_align_${mlss_id}",
        2 * $n_blocks,
        $self->get_requestor_id,
    );

    foreach my $chain (@$chains) {
        my $group_id = $ga_id;
        foreach my $gab (@$chain) {
            my ($ga1, $ga2) = @{$gab->genomic_align_array};
            $gab->dbID($ga_id);
            $ga1->dbID($ga_id);
            $ga2->dbID($ga_id+1);
            $gab->group_id($group_id) unless $gab->group_id;
            $ga_id += 2;
        }
    }
}

1;
