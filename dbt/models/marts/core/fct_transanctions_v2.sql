 {{
      config(
          materialized='incremental',
          unique_key='transaction_id',
          incremental_strategy='merge',
          merge_update_columns=['statut', 'is_reconciled', 'aml_flag',
                                'aml_score', 'fraud_score', 'montant_eur',
                                'montant_hors_taxes', 'updated_at'],
          cluster_by=['tenant_id'],
          on_schema_change='append_new_columns',
          tags=['marts', 'core', 'fct', 'incremental']
      )
  }}

  with base as (
      select * from {{ ref('fct_transactions') }}
      {% if is_incremental() %}
          where _loaded_at >= (select dateadd('day', -{{
  var('incremental_lookback_days', 7) }}, max(_loaded_at)) from {{ this }})
      {% endif %}
  )

  select
      *,
      case
          when type_operation = 'debit' then round(montant_eur / 1.20, 2)
          else montant_eur
      end as montant_hors_taxes

  from base