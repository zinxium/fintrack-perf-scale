-- ============================================================
-- DIM CATÉGORIES — avec hiérarchie récursive résolue (bridge)
-- ============================================================
-- TODO (Sprint 2) : Compléter la résolution hiérarchique.
-- La table catégories a un champ categorie_parent_id qui peut créer
-- une hiérarchie sur plusieurs niveaux.
--
-- Attendus :
--   - categorie_id
--   - nom_categorie
--   - chemin_complet (ex : "Loisirs > Restaurant > Fast-food")
--   - niveau (1 = racine)
--   - id_racine
--
-- Indice : utiliser une CTE récursive Snowflake (WITH RECURSIVE)
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'dim']
    )
}}

    with recursive 

    source as (
        select * from {{ ref('stg_categories') }}
    ),
     hierarchie as (
      -- Ancre : catégories racines (sans parent)
      select
          categorie_id,
          nom_categorie,
          type_categorie,
          groupe,
          categorie_parent_id,
          niveau_hierarchique,
          nom_categorie                    as chemin_complet,
          categorie_id                     as id_racine
      from source
      where categorie_parent_id is null

      union all

      -- Récursion : enfants
      select
          c.categorie_id,
          c.nom_categorie,
          c.type_categorie,
          c.groupe,
          c.categorie_parent_id,
          c.niveau_hierarchique,
          h.chemin_complet || ' > ' || c.nom_categorie as chemin_complet,
          h.id_racine
      from source c
      inner join hierarchie h
          on c.categorie_parent_id = h.categorie_id

  )

  select * from hierarchie

 