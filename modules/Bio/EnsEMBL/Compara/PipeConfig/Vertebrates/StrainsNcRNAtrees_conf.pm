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

Bio::EnsEMBL::Compara::PipeConfig::Vertebrates::StrainsNcRNAtrees_conf

=head1 SYNOPSIS

    init_pipeline.pl Bio::EnsEMBL::Compara::PipeConfig::Vertebrates::StrainsNcRNAtrees_conf -host mysql-ens-compara-prod-X -port XXXX \
        -mlss_id <curr_ncrna_mlss_id> -projection_source_species_names <list_of_species_names> \
        -multifurcation_deletes_all_subnodes <list_of_root_node_to_flatten>

=head1 DESCRIPTION

This is the Strains/Breeds PipeConfig for the Vertebrates ncRNAtrees pipeline.

=cut

package Bio::EnsEMBL::Compara::PipeConfig::Vertebrates::StrainsNcRNAtrees_conf;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Compara::PipeConfig::Vertebrates::ncRNAtrees_conf');

sub default_options {
    my ($self) = @_;

    return {
            %{$self->SUPER::default_options},

            'skip_epo'          => 1,

            # collection in master that will have overlapping data
            'ref_collection'   => 'default',

            # CAFE parameters
            'do_cafe'  => 0,

            'multifurcation_deletes_all_subnodes' => undef,
    };
}

sub pipeline_wide_parameters {  # these parameter values are visible to all analyses, can be overridden by parameters{} and input_id{}
    my ($self) = @_;
    return {
        %{$self->SUPER::pipeline_wide_parameters},          # here we inherit anything from the base class

        'ref_collection'   => $self->o('ref_collection'),
    }
}

sub core_pipeline_analyses {
    my ($self) = @_;
    return [
        @{$self->SUPER::core_pipeline_analyses},

        {   -logic_name => 'check_strains_cluster_factory',
            -module     => 'Bio::EnsEMBL::Hive::RunnableDB::JobFactory',
            -parameters => {
                'inputquery' => 'SELECT root_id AS gene_tree_id FROM gene_tree_root WHERE tree_type = "tree" AND clusterset_id="default"',
            },
            -flow_into  => {
                '2->A' => [ 'cleanup_strains_clusters' ],
                'A->1' => [ 'cluster_qc_factory' ],
            },
            -rc_name    => '1Gb_job',
        },
        {   -logic_name => 'cleanup_strains_clusters',
            -module     => 'Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::RemoveOverlappingClusters',
        },


        {
             -logic_name => 'remove_overlapping_homologies',
             -module     => 'Bio::EnsEMBL::Compara::RunnableDB::GeneTrees::RemoveOverlappingHomologies',
        },
    ]
}

sub tweak_analyses {
    my $self = shift;
    my $analyses_by_name = shift;

    $analyses_by_name->{'insert_member_projections'}->{'-parameters'}->{'source_species_names'} = $self->o('projection_source_species_names');
    $analyses_by_name->{'make_species_tree'}->{'-parameters'}->{'allow_subtaxa'} = 1;  # We have sub-species
    $analyses_by_name->{'make_species_tree'}->{'-parameters'}->{'multifurcation_deletes_all_subnodes'} = $self->o('multifurcation_deletes_all_subnodes');
    $analyses_by_name->{'orthotree_himem'}->{'-rc_name'} = '2Gb_job';

    # wire up strain-specific analyses
    $analyses_by_name->{'expand_clusters_with_projections'}->{'-flow_into'} = 'check_strains_cluster_factory';
    push @{$analyses_by_name->{'backbone_pipeline_finished'}->{'-flow_into'}}, 'remove_overlapping_homologies';
}


1;
