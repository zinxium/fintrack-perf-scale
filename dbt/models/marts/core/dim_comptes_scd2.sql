-- ============================================================
-- DIM COMPTES SCD Type 2 — historisation des changements
-- ============================================================
-- TODO (Sprint 4) : Construire cette dimension à partir du snapshot
-- snapshot_comptes.
--
-- Attendus :
--   - Une ligne par version (date_debut_validite, date_fin_validite)
--   - Colonnes techniques : is_current, version_number
--   - Surrogate key : dbt_utils.generate_surrogate_key(['compte_id', 'date_debut_validite'])
--
-- Indice : utiliser dbt_valid_from et dbt_valid_to du snapshot.
-- Voir docs/DESIGN.md section "SCD2 Pattern".
-- ============================================================

{{                                                                                                                                                                         
      config(                                               
          materialized='table',
          tags=['marts', 'core', 'dim', 'scd2']
      )
  }}

  with snapshot as (
      select * from {{ ref('snapshot_comptes') }}
  ),

  final as (
      select
          {{ dbt_utils.generate_surrogate_key(['compte_id', 'dbt_valid_from']) }}
                                          as dim_compte_sk,
          compte_id,
          tenant_id,
          numero_compte,
          iban,
          email,
          nom_client,
          prenom_client,
          type_compte,
          devise,
          statut,
          kyc_level,
          kyc_date_verification,
          aml_flag,
          customer_segment,
          is_pep,
          risk_score,
          dbt_valid_from              as date_debut_validite,
          dbt_valid_to                as date_fin_validite,
          case when dbt_valid_to is null then true else false end as is_current,
          row_number() over (
              partition by compte_id
              order by dbt_valid_from
          )                           as version_number,
          updated_at
      from snapshot
  )

  select * from final