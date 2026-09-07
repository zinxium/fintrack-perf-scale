{{
    config(
        materialized='view',
        tags=['staging', 'core']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_titulaires') }}
)

select
    titulaire_id,
    nom,
    prenom,
    email,
    telephone,
    date_naissance,
    nationalite,
    pays_residence,
    type_titulaire_defaut,
    is_active,
    created_at,
    _loaded_at

from source
