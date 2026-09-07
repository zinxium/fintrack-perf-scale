-- ============================================================
-- BRIDGE COMPTES ↔ TITULAIRES (relation many-to-many)
-- ============================================================
-- Gère les comptes joints : un compte peut avoir plusieurs
-- titulaires, un titulaire peut avoir plusieurs comptes.
--
-- allocation_factor : poids pour la ventilation des montants.
--   Exemple : compte joint à 2 cotitulaires actifs → 0.5 chacun.
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'bridge']
    )
}}

with liaisons as (
    select * from {{ ref('stg_compte_titulaires') }}
),

-- Nombre de titulaires actifs par compte (pour le calcul du facteur)
nb_titulaires_actifs as (
    select
        compte_id,
        count(*) as nb_actifs
    from liaisons
    where is_active = true
    group by compte_id
),

final as (
    select
        l.id                                                as bridge_id,
        l.compte_id,
        l.titulaire_id,
        l.type_relation,
        l.date_debut,
        l.date_fin,
        l.is_active,

        -- is_primary : vrai uniquement pour le titulaire principal
        l.type_relation = 'principal'                       as is_primary,

        -- allocation_factor : répartition équitable entre titulaires actifs
        case
            when l.is_active = false then 0.0
            else 1.0 / nullif(n.nb_actifs, 0)
        end                                                 as allocation_factor,

        l._loaded_at
    from liaisons l
    left join nb_titulaires_actifs n
        on l.compte_id = n.compte_id
)

select * from final
