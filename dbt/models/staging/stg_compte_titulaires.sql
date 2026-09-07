{{
    config(
        materialized='view',
        tags=['staging', 'core']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_compte_titulaires') }}
)

select
    id,
    compte_id,
    titulaire_id,
    type_relation,
    date_debut,
    date_fin,
    is_active,
    created_at,
    _loaded_at

from source
