 -- ============================================================
  -- FCT TRANSACTIONS MICROBATCH — prototype stratégie microbatch                                                                                                            
  -- ============================================================
  -- Comparaison avec fct_transactions (merge) pour benchmark perf.                                                                                                          
  -- Microbatch : dbt découpe par fenêtres journalières et remplace
  -- chaque batch entier — pas de merge row-by-row.
  --
  -- Avantages microbatch vs merge :
  --   + Parallélisable (plusieurs jours en parallèle)
  --   + Pas de surrogate key ni de merge coûteux
  --   - Ne gère pas les mises à jour de statut (pas idéal ici)
  -- ============================================================

{{
      config(
          materialized='incremental',
          incremental_strategy='microbatch',
          event_time='date_transaction',
          begin='2023-01-01',
          batch_size='day',
          lookback=3,
          cluster_by=['tenant_id'],
          on_schema_change='append_new_columns',
          tags=['marts', 'core', 'fct', 'microbatch', 'benchmark']
      )
}}

  with base as (
      select * from {{ ref('int_transactions_normalisees') }}
  ),

  fx as (
      select
          date_cotation,
          devise_cible as devise,
          taux
      from {{ ref('int_fx_rates_daily') }}
  )

  select
      b.transaction_id,
      b.external_transaction_id,
      b.tenant_id,
      b.compte_id,
      b.categorie_id,

      b.date_transaction,
      b.jour_transaction,
      b.semaine_transaction,
      b.mois_transaction,
      b.date_valeur,
      b.date_settlement,

      b.montant,
      b.devise,
      round(b.montant * coalesce(fx.taux, b.taux_change_applique, 1), 2) as montant_eur,
      b.montant_signe,
      b.montant_signe_eur,
      b.frais,
      b.montant_net,

      b.type_operation,
      b.sens,
      b.statut,
      b.moyen_paiement,
      b.canal,

      b.type_compte,
      b.customer_segment,
      b.pays_compte,
      b.nom_categorie,
      b.type_categorie,
      b.groupe,

      b.marchand_nom,
      b.marchand_categorie,
      b.marchand_pays,
      b.marchand_mcc,

      b.aml_score,
      b.aml_flag,
      b.fraud_score,
      b.is_flagged_for_review,

      b.is_reconciled,
      b.reconciliation_batch_id,

      b.source_system,
      b.created_at,
      b.updated_at,
      b._loaded_at

  from base b
  left join fx
      on b.jour_transaction = fx.date_cotation
     and b.devise = fx.devise
  where b.statut in ('validee', 'en_attente')
    and b.is_reversal = false