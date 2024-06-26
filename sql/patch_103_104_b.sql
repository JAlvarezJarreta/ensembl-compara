-- See the NOTICE file distributed with this work for additional information
-- regarding copyright ownership.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

# patch_103_104_b.sql
#
# Title: Add new table to store alt-loci
#
# Description:
#   Add new table to record which part of the non-reference dnafrags
#   actually differ from the primary assembly.

CREATE TABLE dnafrag_alt_region (
  dnafrag_id                 BIGINT UNSIGNED NOT NULL,
  dnafrag_start              INT UNSIGNED NOT NULL,
  dnafrag_end                INT UNSIGNED NOT NULL,

  FOREIGN KEY (dnafrag_id) REFERENCES dnafrag(dnafrag_id),

  PRIMARY KEY (dnafrag_id)
) ENGINE=MyISAM;

# Patch identifier
INSERT INTO meta (species_id, meta_key, meta_value)
  VALUES (NULL, 'patch', 'patch_103_104_b.sql|dnafrag_alt_region');
