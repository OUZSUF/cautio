-- =====================================================================
--  SUIVI DES CAUTIONS – MARCHÉS PUBLICS (MAROC) – Schéma Supabase
--  À coller tel quel dans : Supabase > SQL Editor > New query > Run
--
--  Références juridiques intégrées (valeurs par défaut modifiables
--  dans la table `parametres_juridiques`) :
--   • Décret n° 2-22-431 du 8 mars 2023 relatif aux marchés publics
--     (art. 24 : cautionnement provisoire) – en vigueur depuis 01/09/2023
--   • CCAG-Travaux : décret n° 2-14-394 du 13 mai 2016
--     (art. 14 à 19 : cautionnement définitif, retenue de garantie,
--      restitution / mainlevée ; délai de garantie)
--   • Dahir n° 1-56-211 du 8 juin 1956 relatif aux garanties pécuniaires
--   • Décret n° 2-14-272 du 14 mai 2014 relatif aux avances
--     (caution personnelle et solidaire de restitution d'avance)
--  ⚠ Le CPS de chaque marché prime pour les taux et délais : saisissez
--    les valeurs du CPS dans la fiche marché (elles écrasent les défauts).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. TYPES
-- ---------------------------------------------------------------------
do $$ begin
  create type type_caution as enum (
    'provisoire',          -- garantit la soumission (art. 24 décret 2-22-431)
    'definitive',          -- garantit la bonne exécution (CCAG-T)
    'retenue_garantie',    -- caution remplaçant la retenue de garantie
    'restitution_avance'   -- garantit le remboursement de l'avance
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type forme_caution as enum (
    'caution_bancaire',    -- caution personnelle et solidaire (banque)
    'depot_cdg',           -- numéraire consigné à la CDG / Trésorerie
    'assurance'            -- caution d'une compagnie agréée
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type statut_caution as enum (
    'demandee',            -- demande faite à la banque
    'deposee',             -- remise au maître d'ouvrage
    'active',              -- en cours de validité
    'mainlevee_demandee',  -- lettre de demande de mainlevée envoyée
    'mainlevee_obtenue',   -- mainlevée signée par le MO
    'liberee',             -- restituée / libérée à la banque (clôturée)
    'confisquee'           -- saisie par le maître d'ouvrage
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type statut_marche as enum (
    'soumission', 'attribue', 'approuve', 'en_cours',
    'reception_provisoire', 'reception_definitive', 'resilie', 'perdu', 'cloture'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- 2. PARAMÈTRES JURIDIQUES (valeurs par défaut)
-- ---------------------------------------------------------------------
create table if not exists parametres_juridiques (
  cle         text primary key,
  valeur      numeric not null,
  unite       text,
  reference   text,
  description text
);

insert into parametres_juridiques (cle, valeur, unite, reference, description) values
 ('taux_caution_definitive',        3,   '%',     'CCAG-T art. 15 / CPS',  'Taux usuel du cautionnement définitif sur le montant initial du marché'),
 ('delai_constitution_definitive',  30,  'jours', 'CCAG-T art. 15 / CPS',  'Délai pour constituer le cautionnement définitif après notification de l''approbation (vérifier le CPS : souvent 20 ou 30 j)'),
 ('taux_retenue_par_acompte',       10,  '%',     'CCAG-T art. 16 / CPS',  'Retenue de garantie prélevée sur chaque acompte'),
 ('plafond_retenue_garantie',       7,   '%',     'CCAG-T art. 16 / CPS',  'Plafond de la retenue de garantie (montant initial + avenants)'),
 ('delai_garantie_mois',            12,  'mois',  'CCAG-T / CPS',          'Délai de garantie entre réception provisoire et réception définitive'),
 ('delai_restitution_apres_rd',     3,   'mois',  'CCAG-T art. 19',        'Délai max de restitution du cautionnement définitif / retenue après réception définitive'),
 ('alerte_expiration_jours',        30,  'jours', 'interne',               'Alerter X jours avant la date d''expiration d''une caution bancaire')
on conflict (cle) do nothing;

create or replace function param(p_cle text) returns numeric
language sql stable as $$ select valeur from parametres_juridiques where cle = p_cle $$;

-- ---------------------------------------------------------------------
-- 3. RÉFÉRENTIELS
-- ---------------------------------------------------------------------
create table if not exists entreprises (          -- vos sociétés (si plusieurs)
  id          uuid primary key default gen_random_uuid(),
  raison_sociale text not null,
  ice         text,
  rc          text,
  owner_id    uuid default auth.uid(),
  created_at  timestamptz default now()
);

create table if not exists banques (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,
  agence      text,
  contact     text,
  telephone   text,
  ligne_cautions_autorisee numeric(16,2),       -- plafond accordé par la banque
  owner_id    uuid default auth.uid(),
  created_at  timestamptz default now()
);

create table if not exists maitres_ouvrage (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,                    -- ex : Commune X, ONEE, Ministère…
  ville       text,
  contact     text,
  telephone   text,
  email       text,
  owner_id    uuid default auth.uid(),
  created_at  timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 4. MARCHÉS
-- ---------------------------------------------------------------------
create table if not exists marches (
  id                     uuid primary key default gen_random_uuid(),
  entreprise_id          uuid references entreprises(id) on delete set null,
  maitre_ouvrage_id      uuid references maitres_ouvrage(id) on delete set null,
  numero_ao              text,                  -- n° appel d'offres
  numero_marche          text,                  -- n° marché après attribution
  objet                  text not null,
  type_prestation        text check (type_prestation in ('travaux','fournitures','services','etudes')) default 'travaux',
  statut                 statut_marche not null default 'soumission',

  -- Montants (TTC)
  montant_estimation     numeric(16,2),
  montant_initial        numeric(16,2),         -- montant de l'offre retenue
  montant_avenants       numeric(16,2) default 0,
  montant_avance         numeric(16,2) default 0,

  -- Taux / délais du CPS (laisser vide = valeur par défaut légale)
  cps_taux_definitive    numeric(5,2),
  cps_delai_constitution integer,
  cps_taux_retenue       numeric(5,2),
  cps_plafond_retenue    numeric(5,2),
  cps_delai_garantie_mois integer,
  cps_montant_provisoire numeric(16,2),         -- fixé en valeur dans le RC

  -- Dates clés
  date_ouverture_plis    date,
  date_notification_approbation date,
  date_ordre_service     date,
  delai_execution_mois   numeric(6,2),
  date_reception_provisoire date,
  date_reception_definitive date,

  observations           text,
  owner_id               uuid default auth.uid(),
  created_at             timestamptz default now(),
  updated_at             timestamptz default now()
);

-- Décomptes / acomptes (pour calculer la retenue de garantie cumulée)
create table if not exists decomptes (
  id            uuid primary key default gen_random_uuid(),
  marche_id     uuid not null references marches(id) on delete cascade,
  numero        integer not null,
  date_decompte date not null,
  montant_acompte numeric(16,2) not null,       -- montant des travaux du décompte (TTC)
  retenue_garantie numeric(16,2),                -- calculé automatiquement si vide
  remboursement_avance numeric(16,2) default 0,
  owner_id      uuid default auth.uid(),
  created_at    timestamptz default now(),
  unique (marche_id, numero)
);

-- ---------------------------------------------------------------------
-- 5. CAUTIONS
-- ---------------------------------------------------------------------
create table if not exists cautions (
  id                 uuid primary key default gen_random_uuid(),
  marche_id          uuid not null references marches(id) on delete cascade,
  banque_id          uuid references banques(id) on delete set null,
  type               type_caution not null,
  forme              forme_caution not null default 'caution_bancaire',
  statut             statut_caution not null default 'demandee',

  numero_caution     text,                      -- réf. banque ou récépissé CDG
  montant            numeric(16,2),             -- calculé automatiquement si vide
  commission_taux    numeric(6,3),              -- % annuel / trimestriel facturé par la banque
  commission_periodicite text check (commission_periodicite in ('mensuelle','trimestrielle','semestrielle','annuelle')) default 'trimestrielle',

  date_emission      date,
  date_depot_mo      date,                      -- remise au maître d'ouvrage
  date_expiration    date,                      -- si la caution bancaire a une échéance
  date_limite_constitution date,               -- calculée pour la définitive
  date_mainlevee_prevue date,                   -- calculée selon le type
  date_demande_mainlevee date,
  date_mainlevee     date,
  date_liberation    date,                      -- retour de l'original à la banque
  montant_confisque  numeric(16,2),
  motif_confiscation text,

  fichier_caution_url   text,                   -- lien Supabase Storage
  fichier_mainlevee_url text,
  observations       text,
  owner_id           uuid default auth.uid(),
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

create index if not exists idx_cautions_marche on cautions(marche_id);
create index if not exists idx_cautions_statut on cautions(statut);
create index if not exists idx_decomptes_marche on decomptes(marche_id);

-- Historique des changements de statut
create table if not exists cautions_historique (
  id          bigint generated always as identity primary key,
  caution_id  uuid not null references cautions(id) on delete cascade,
  ancien_statut statut_caution,
  nouveau_statut statut_caution,
  date_changement timestamptz default now(),
  user_id     uuid default auth.uid()
);

-- ---------------------------------------------------------------------
-- 6. LOGIQUE MÉTIER (fonctions + triggers)
-- ---------------------------------------------------------------------

-- 6.1 Montant de la retenue de garantie sur un décompte (10 % plafonné à 7 %)
create or replace function calc_retenue_decompte() returns trigger
language plpgsql as $$
declare
  m        marches%rowtype;
  taux     numeric;
  plafond  numeric;
  deja     numeric;
begin
  if new.retenue_garantie is not null then return new; end if;
  select * into m from marches where id = new.marche_id;
  taux    := coalesce(m.cps_taux_retenue,    param('taux_retenue_par_acompte')) / 100;
  plafond := coalesce(m.cps_plafond_retenue, param('plafond_retenue_garantie')) / 100
             * (coalesce(m.montant_initial,0) + coalesce(m.montant_avenants,0));
  select coalesce(sum(retenue_garantie),0) into deja
    from decomptes where marche_id = new.marche_id and id <> new.id;
  new.retenue_garantie := round(greatest(0, least(new.montant_acompte * taux, plafond - deja)), 2);
  return new;
end $$;

drop trigger if exists trg_retenue_decompte on decomptes;
create trigger trg_retenue_decompte before insert or update on decomptes
for each row execute function calc_retenue_decompte();

-- 6.2 Calcul automatique du montant et des dates d'une caution
create or replace function calc_caution() returns trigger
language plpgsql as $$
declare
  m marches%rowtype;
  delai_gar int;
begin
  select * into m from marches where id = new.marche_id;
  delai_gar := coalesce(m.cps_delai_garantie_mois, param('delai_garantie_mois'))::int;

  -- Montant par défaut
  if new.montant is null then
    new.montant := case new.type
      when 'provisoire'         then m.cps_montant_provisoire
      when 'definitive'         then ceil(coalesce(m.montant_initial,0)
                                      * coalesce(m.cps_taux_definitive, param('taux_caution_definitive')) / 100)  -- arrondi au dirham supérieur
      when 'retenue_garantie'   then round(coalesce(m.cps_plafond_retenue, param('plafond_retenue_garantie')) / 100
                                      * (coalesce(m.montant_initial,0) + coalesce(m.montant_avenants,0)), 2)
      when 'restitution_avance' then m.montant_avance
    end;
  end if;

  -- Date limite de constitution du définitif
  if new.type = 'definitive' and m.date_notification_approbation is not null then
    new.date_limite_constitution := m.date_notification_approbation
      + coalesce(m.cps_delai_constitution, param('delai_constitution_definitive'))::int;
  end if;

  -- Date de mainlevée prévue
  new.date_mainlevee_prevue := case new.type
    -- provisoire : restituée dès la constitution du définitif (attributaire)
    -- ou dès l'annonce du résultat (concurrent non retenu)
    when 'provisoire' then coalesce(
        (select min(date_depot_mo) from cautions c
          where c.marche_id = new.marche_id and c.type = 'definitive' and c.id <> new.id),
        case when m.statut = 'perdu' then current_date end)
    -- définitive / retenue : après réception définitive (+ délai max de restitution)
    when 'definitive' then
        (coalesce(m.date_reception_definitive,
                  m.date_reception_provisoire + make_interval(months => delai_gar))
         + make_interval(months => param('delai_restitution_apres_rd')::int))::date
    when 'retenue_garantie' then
        (coalesce(m.date_reception_definitive,
                  m.date_reception_provisoire + make_interval(months => delai_gar))
         + make_interval(months => param('delai_restitution_apres_rd')::int))::date
    -- avance : libérée lorsque l'avance est totalement remboursée sur les décomptes
    when 'restitution_avance' then
        (select min(d.date_decompte) from decomptes d
          where d.marche_id = new.marche_id
            and (select sum(remboursement_avance) from decomptes d2
                  where d2.marche_id = new.marche_id and d2.numero <= d.numero) >= coalesce(m.montant_avance,0)
            and coalesce(m.montant_avance,0) > 0)
  end;

  -- Statut automatique de base
  if new.date_liberation is not null then new.statut := 'liberee';
  elsif new.date_mainlevee is not null and new.statut not in ('liberee','confisquee') then new.statut := 'mainlevee_obtenue';
  elsif new.date_demande_mainlevee is not null and new.statut in ('demandee','deposee','active') then new.statut := 'mainlevee_demandee';
  elsif new.date_depot_mo is not null and new.statut in ('demandee','deposee') then new.statut := 'active';
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_calc_caution on cautions;
create trigger trg_calc_caution before insert or update on cautions
for each row execute function calc_caution();

-- 6.3 Historique des statuts
create or replace function log_statut_caution() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.statut is distinct from old.statut then
    insert into cautions_historique (caution_id, ancien_statut, nouveau_statut)
    values (new.id, case when tg_op = 'UPDATE' then old.statut end, new.statut);
  end if;
  return new;
end $$;

drop trigger if exists trg_log_statut on cautions;
create trigger trg_log_statut after insert or update on cautions
for each row execute function log_statut_caution();

-- 6.4 Quand le marché change (réceptions, avenants…) → recalculer ses cautions
create or replace function recalc_cautions_marche() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_marche_updated on marches;
create trigger trg_marche_updated before update on marches
for each row execute function recalc_cautions_marche();

create or replace function refresh_cautions_after_marche() returns trigger
language plpgsql as $$
begin
  update cautions set updated_at = now() where marche_id = new.id;  -- déclenche calc_caution
  return null;
end $$;

drop trigger if exists trg_refresh_cautions on marches;
create trigger trg_refresh_cautions after update on marches
for each row execute function refresh_cautions_after_marche();

create or replace function refresh_cautions_after_decompte() returns trigger
language plpgsql as $$
begin
  update cautions set updated_at = now()
   where marche_id = coalesce(new.marche_id, old.marche_id) and type = 'restitution_avance';
  return null;
end $$;

drop trigger if exists trg_refresh_cautions_dec on decomptes;
create trigger trg_refresh_cautions_dec after insert or update or delete on decomptes
for each row execute function refresh_cautions_after_decompte();

-- Quand une caution définitive est déposée → mettre à jour la date de mainlevée du provisoire
create or replace function refresh_provisoire() returns trigger
language plpgsql as $$
begin
  if new.type = 'definitive' then
    update cautions set updated_at = now()
     where marche_id = new.marche_id and type = 'provisoire';
  end if;
  return null;
end $$;

drop trigger if exists trg_refresh_provisoire on cautions;
create trigger trg_refresh_provisoire after insert or update of date_depot_mo on cautions
for each row execute function refresh_provisoire();

-- ---------------------------------------------------------------------
-- 7. VUES DE SUIVI (tableau de bord)
-- ---------------------------------------------------------------------

-- 7.1 Toutes les cautions avec alertes
create or replace view v_cautions_suivi with (security_invoker = true) as
select
  c.id, c.type, c.forme, c.statut, c.numero_caution, c.montant,
  m.numero_marche, m.numero_ao, m.objet, m.statut as statut_marche,
  mo.nom  as maitre_ouvrage,
  b.nom   as banque,
  c.date_depot_mo, c.date_expiration, c.date_limite_constitution,
  c.date_mainlevee_prevue, c.date_demande_mainlevee, c.date_mainlevee, c.date_liberation,
  -- Alerte
  case
    when c.statut in ('liberee','confisquee') then null
    when c.type = 'definitive' and c.date_depot_mo is null
         and c.date_limite_constitution < current_date
      then '🔴 Définitif NON constitué – délai dépassé (risque de perte du provisoire)'
    when c.type = 'definitive' and c.date_depot_mo is null
         and c.date_limite_constitution <= current_date + 7
      then '🟠 Définitif à constituer avant le ' || to_char(c.date_limite_constitution,'DD/MM/YYYY')
    when c.date_expiration is not null and c.date_expiration < current_date
      then '🔴 Caution EXPIRÉE – à proroger'
    when c.date_expiration is not null
         and c.date_expiration <= current_date + param('alerte_expiration_jours')::int
      then '🟠 Expire le ' || to_char(c.date_expiration,'DD/MM/YYYY') || ' – demander prorogation'
    when c.statut = 'mainlevee_obtenue'
      then '🔵 Mainlevée obtenue – rendre l''original à la banque / CDG'
    when c.date_mainlevee_prevue is not null and c.date_mainlevee_prevue <= current_date
         and c.statut in ('active','deposee')
      then '🟢 Mainlevée exigible – faire la demande au maître d''ouvrage'
    when c.statut = 'mainlevee_demandee' and c.date_demande_mainlevee < current_date - 30
      then '🟠 Mainlevée demandée il y a +30 j – relancer'
  end as alerte,
  (c.date_mainlevee_prevue - current_date) as jours_avant_mainlevee,
  c.marche_id, c.banque_id
from cautions c
join marches m           on m.id = c.marche_id
left join maitres_ouvrage mo on mo.id = m.maitre_ouvrage_id
left join banques b      on b.id = c.banque_id;

-- 7.2 Uniquement les cautions qui demandent une action
create or replace view v_alertes with (security_invoker = true) as
select * from v_cautions_suivi where alerte is not null
order by left(alerte, 2) = '🔴' desc, date_mainlevee_prevue nulls last;

-- 7.3 Engagement par banque (utilisation de la ligne de cautions)
create or replace view v_engagement_banques with (security_invoker = true) as
select
  b.id, b.nom, b.ligne_cautions_autorisee,
  coalesce(sum(c.montant) filter (where c.statut not in ('liberee','confisquee')), 0) as encours,
  b.ligne_cautions_autorisee
    - coalesce(sum(c.montant) filter (where c.statut not in ('liberee','confisquee')), 0) as disponible,
  count(c.id) filter (where c.statut not in ('liberee','confisquee')) as nb_cautions_actives
from banques b
left join cautions c on c.banque_id = b.id
group by b.id;

-- 7.4 Synthèse par marché (retenue de garantie cumulée, cautions)
create or replace view v_synthese_marches with (security_invoker = true) as
select
  m.id, m.numero_marche, m.objet, m.statut,
  mo.nom as maitre_ouvrage,
  m.montant_initial, m.montant_avenants,
  coalesce((select sum(montant_acompte)   from decomptes d where d.marche_id = m.id),0) as cumul_decomptes,
  coalesce((select sum(retenue_garantie)  from decomptes d where d.marche_id = m.id),0) as cumul_retenue_garantie,
  coalesce((select sum(remboursement_avance) from decomptes d where d.marche_id = m.id),0) as avance_remboursee,
  coalesce((select sum(montant) from cautions c where c.marche_id = m.id
             and c.statut not in ('liberee','confisquee')),0) as cautions_en_cours,
  m.date_reception_provisoire, m.date_reception_definitive
from marches m
left join maitres_ouvrage mo on mo.id = m.maitre_ouvrage_id;

-- 7.5 Coût des commissions bancaires (estimation à ce jour)
create or replace view v_cout_commissions with (security_invoker = true) as
select
  c.id, m.numero_marche, b.nom as banque, c.type, c.montant, c.commission_taux,
  c.date_emission,
  coalesce(c.date_liberation, current_date) as date_fin,
  round(c.montant * coalesce(c.commission_taux,0) / 100
        * ((coalesce(c.date_liberation, current_date) - c.date_emission)::numeric / 365)
        * case c.commission_periodicite when 'mensuelle' then 12 when 'trimestrielle' then 4
                                        when 'semestrielle' then 2 else 1 end, 2) as cout_estime
from cautions c
join marches m on m.id = c.marche_id
left join banques b on b.id = c.banque_id
where c.forme = 'caution_bancaire' and c.date_emission is not null;

-- ---------------------------------------------------------------------
-- 8. SÉCURITÉ (Row Level Security) : chaque utilisateur voit ses données
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['entreprises','banques','maitres_ouvrage','marches','decomptes','cautions']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%1$s_owner" on %1$I', t);
    execute format($p$create policy "%1$s_owner" on %1$I
                     for all using (owner_id = auth.uid()) with check (owner_id = auth.uid())$p$, t);
  end loop;
end $$;

alter table cautions_historique enable row level security;
drop policy if exists "historique_owner" on cautions_historique;
create policy "historique_owner" on cautions_historique for select
  using (exists (select 1 from cautions c where c.id = caution_id and c.owner_id = auth.uid()));

alter table parametres_juridiques enable row level security;
drop policy if exists "parametres_lecture" on parametres_juridiques;
create policy "parametres_lecture" on parametres_juridiques for select using (auth.role() = 'authenticated');

-- Les triggers écrivent dans l'historique même si l'utilisateur n'a qu'un SELECT
alter function log_statut_caution() security definer;
alter function log_statut_caution() set search_path = public;

-- ---------------------------------------------------------------------
-- 9. STOCKAGE DES SCANS (cautions, mainlevées, récépissés CDG)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documents-cautions', 'documents-cautions', false)
on conflict (id) do nothing;

drop policy if exists "docs_cautions_owner" on storage.objects;
create policy "docs_cautions_owner" on storage.objects for all
  using (bucket_id = 'documents-cautions' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'documents-cautions' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 10. ACCÈS À L'API (nécessaire si « Grant API access » est désactivé)
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on entreprises, banques, maitres_ouvrage, marches, decomptes, cautions to authenticated;
grant select on cautions_historique, parametres_juridiques to authenticated;
grant select on v_cautions_suivi, v_alertes, v_engagement_banques, v_synthese_marches, v_cout_commissions to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function param(text) to authenticated;

-- =====================================================================
-- FIN. Exemples d'utilisation :
--   select * from v_alertes;              -- ce qu'il faut faire aujourd'hui
--   select * from v_engagement_banques;   -- encours par banque
--   select * from v_synthese_marches;     -- vue d'ensemble des marchés
-- =====================================================================
