--
-- PostgreSQL database dump
--

\restrict tdKnhmigJeJxBsRQQgPmJopeXyHehkcwWkYdHwYTEbjasYJOsAcjdyKSyRs4fBH

-- Dumped from database version 18.3 (Debian 18.3-1.pgdg12+1)
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

--
-- Name: brain; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS brain;


--
-- Name: brand; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS brand;


--
-- Name: factory; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS factory;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: fn_delete_semantic_index_for_source(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_delete_semantic_index_for_source() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_source_id TEXT;
BEGIN
  IF TG_TABLE_NAME = 'agent_identity' THEN
    v_source_id := OLD.agent_name;
  ELSIF TG_TABLE_NAME = 'sop_registry' THEN
    v_source_id := OLD.sop_id;
  ELSE
    v_source_id := OLD.id::text;
  END IF;

  DELETE FROM semantic_index
   WHERE tenant_id = COALESCE(OLD.tenant_id, 'omatic')
     AND source_table = TG_TABLE_NAME
     AND source_id = v_source_id;
  RETURN OLD;
END $$;


--
-- Name: fn_document_chunk_delete_cleanup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_document_chunk_delete_cleanup() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
        DELETE FROM brain.semantic_index
         WHERE tenant_id = COALESCE(OLD.tenant_id, 'omatic')
           AND source_table = 'document_chunks'
           AND source_id = OLD.id::text;
        RETURN OLD;
      END $$;


--
-- Name: fn_mark_document_chunk_stale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_mark_document_chunk_stale() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
        NEW.embedding_stale := true;
        RETURN NEW;
      END $$;


--
-- Name: fn_mark_embedding_stale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_mark_embedding_stale() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_source_id TEXT;
BEGIN
  -- agent_identity uses agent_name as natural key; others use id
  IF TG_TABLE_NAME = 'agent_identity' THEN
    v_source_id := NEW.agent_name;
  ELSIF TG_TABLE_NAME = 'sop_registry' THEN
    v_source_id := NEW.sop_id;
  ELSE
    v_source_id := NEW.id::text;
  END IF;

  UPDATE semantic_index
     SET embedding_stale = true
   WHERE tenant_id = COALESCE(NEW.tenant_id, OLD.tenant_id, 'omatic')
     AND source_table = TG_TABLE_NAME
     AND source_id = v_source_id;
  RETURN NEW;
END $$;


--
-- Name: fn_persona_identity_signature(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_persona_identity_signature(p_version_id integer) RETURNS text
    LANGUAGE sql STABLE
    AS $$
  WITH ver AS (
    SELECT 'V|'||coalesce(role,'~')||'|'||coalesce(one_liner,'~')||'|'||coalesce(summary,'~')
           ||'|'||array_to_string(trigger_phrases,'#') AS s
    FROM persona_version WHERE id=p_version_id
  ),
  bible AS (
    SELECT 'B|'||coalesce(archetype,'~')||'|'||coalesce(backstory,'~')||'|'||coalesce(personality,'~')
           ||'|'||coalesce(character_depth,'~')||'|'||coalesce(humor,'~')||'|'||coalesce(seriousness_boundary,'~')
           ||'|'||coalesce(evolution_history,'~')||'|'||array_to_string(traits,'#')||'|'||coalesce(emoji,'~') AS s
    FROM persona_character_bible WHERE version_id=p_version_id
  ),
  voice AS (
    SELECT 'VC|'||coalesce(opening_convention,'~')||'|'||coalesce(register,'~')||'|'||coalesce(voice_texture,'~')
           ||'|'||array_to_string(voice_anchors,'#')||'|'||array_to_string(sample_lines,'#')
           ||'|'||array_to_string(forbidden_phrasings,'#')||'|'||coalesce(emoji_policy,'~') AS s
    FROM persona_voice_contract WHERE version_id=p_version_id
  ),
  lane AS (
    SELECT 'L|'||coalesce(primary_domain,'~')||'|'||array_to_string(does,'#')||'|'||array_to_string(does_not,'#')
           ||'|'||coalesce(handoffs::text,'~')||'|'||coalesce(suppression_rules,'~') AS s
    FROM persona_lane_contract WHERE version_id=p_version_id
  ),
  arch AS (
    SELECT string_agg('A|'||layer||'|'||archetype_name||'|'||coalesce(description,'~'),'||' ORDER BY sort_order,layer) AS s
    FROM persona_archetype WHERE version_id=p_version_id
  ),
  dims AS (
    SELECT string_agg('D|'||dimension||'|'||content,'||' ORDER BY sort_order,dimension) AS s
    FROM persona_character_dimension WHERE version_id=p_version_id
  ),
  str AS (
    SELECT string_agg('S|'||strength||'|'||coalesce(description,'~'),'||' ORDER BY sort_order,strength) AS s
    FROM persona_strength WHERE version_id=p_version_id
  )
  SELECT md5(
    coalesce((SELECT s FROM ver),'')  ||chr(30)||
    coalesce((SELECT s FROM bible),'')||chr(30)||
    coalesce((SELECT s FROM voice),'')||chr(30)||
    coalesce((SELECT s FROM lane),'') ||chr(30)||
    coalesce((SELECT s FROM arch),'') ||chr(30)||
    coalesce((SELECT s FROM dims),'') ||chr(30)||
    coalesce((SELECT s FROM str),'')
  );
$$;


--
-- Name: fn_record_probe_result(text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_record_probe_result(p_connector_id text, p_session_id integer, p_result text, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Update mcp_registry persistent probe status
  UPDATE mcp_registry
  SET probe_status  = p_result,
      last_probed_at = NOW()
  WHERE connector_id = p_connector_id;

  -- Update or insert session_mcp_status for this session
  INSERT INTO session_mcp_status (
    session_id, connector_id, platform, probe_result, probe_note, fallback_active, probed_at
  )
  SELECT
    p_session_id,
    p_connector_id,
    COALESCE(fs.platform, 'unknown'),
    p_result,
    p_note,
    false,
    NOW()
  FROM factory_sessions fs
  WHERE fs.id = p_session_id
  ON CONFLICT DO NOTHING;

  -- If row already exists, update it
  UPDATE session_mcp_status
  SET probe_result   = p_result,
      probe_note     = p_note,
      fallback_active = false,
      probed_at      = NOW()
  WHERE session_id   = p_session_id
    AND connector_id = p_connector_id;
END;
$$;


--
-- Name: fn_record_retrieval_event(text, text, boolean, jsonb, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_record_retrieval_event(p_query_text text, p_search_function text, p_used_vector boolean, p_result_ids jsonb DEFAULT '[]'::jsonb, p_latency_ms integer DEFAULT NULL::integer, p_caller text DEFAULT NULL::text, p_tenant_id text DEFAULT 'omatic'::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO factory.retrieval_events (
    tenant_id, caller, search_function, query_text, used_vector, result_ids, latency_ms
  )
  VALUES (
    p_tenant_id, p_caller, p_search_function, p_query_text, p_used_vector,
    COALESCE(p_result_ids, '[]'::jsonb), p_latency_ms
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


--
-- Name: fn_refresh_dashboards(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_refresh_dashboards() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Non-concurrent: mv_dashboard is a single-row aggregate with no unique key,
  -- so CONCURRENTLY is impossible. The brief refresh lock is negligible at
  -- factory write volume, and matches fn_refresh_startup's approach.
  REFRESH MATERIALIZED VIEW mv_dashboard;
  REFRESH MATERIALIZED VIEW mv_embedding_health;
  REFRESH MATERIALIZED VIEW mv_agent_eval_status;
  REFRESH MATERIALIZED VIEW mv_factory_kernel_health;
END;
$$;


--
-- Name: fn_refresh_startup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_refresh_startup() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_startup_snapshot;
  REFRESH MATERIALIZED VIEW mv_dashboard;  -- non-concurrent: index on constant (true)
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_embedding_health;
END;
$$;


--
-- Name: fn_render_l1_skill(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_render_l1_skill(p_version_id integer) RETURNS text
    LANGUAGE sql STABLE
    AS $$
SELECT
'<!-- GENERATED ARTIFACT — rendered from O-Matic persona record. Do not hand-edit. -->'||E'\n'||
'<!-- agent: '||p.agent_name||' | version: '||pv.version||' | identity_version: '||coalesce(pv.identity_version::text,'?')||' | identity_signature: '||coalesce(pv.identity_signature,'UNSIGNED')||' -->'||E'\n\n'||
'# '||initcap(p.agent_name)||coalesce(' — '||pv.role,'')||E'\n\n'||
coalesce('> '||pv.one_liner||E'\n\n','')||
'**Callsign:** '||p.callsign||' | **Factory:** '||p.factory_type||' | **Status:** '||p.status||coalesce(' | **Emoji:** '||b.emoji,'')||E'\n\n'||
'## Identity'||E'\n\n'||coalesce(pv.summary,'')||E'\n\n'||
coalesce('**Trigger phrases:** '||array_to_string(pv.trigger_phrases,', ')||E'\n\n','')||
'## Archetype Hierarchy'||E'\n\n'||
coalesce((SELECT string_agg('- **'||layer||'** — '||archetype_name||': '||coalesce(description,''),E'\n' ORDER BY sort_order,layer) FROM persona_archetype WHERE version_id=p_version_id),'')||E'\n\n'||
coalesce('> Guardrail: '||b.archetype||E'\n\n','')||
'## Character'||E'\n\n'||
coalesce('**Personality.** '||b.personality||E'\n\n','')||
coalesce('**Backstory.** '||b.backstory||E'\n\n','')||
coalesce('**Depth.** '||b.character_depth||E'\n\n','')||
coalesce('**Humor.** '||b.humor||E'\n\n','')||
coalesce('**Seriousness boundary.** '||b.seriousness_boundary||E'\n\n','')||
coalesce('**Traits:** '||array_to_string(b.traits,', ')||E'\n\n','')||
'### Character Dimensions'||E'\n\n'||
coalesce((SELECT string_agg('- **'||dimension||'** — '||content,E'\n' ORDER BY sort_order,dimension) FROM persona_character_dimension WHERE version_id=p_version_id),'')||E'\n\n'||
'## Voice'||E'\n\n'||
coalesce('**Opening convention.** '||v.opening_convention||E'\n\n','')||
coalesce('**Register.** '||v.register||E'\n\n','')||
coalesce('**Texture.** '||v.voice_texture||E'\n\n','')||
coalesce('**Anchors:** '||array_to_string(v.voice_anchors,' · ')||E'\n\n','')||
coalesce('**Sample lines:**'||E'\n\n> '||array_to_string(v.sample_lines,E'\n> ')||E'\n\n','')||
coalesce('**Forbidden:**'||E'\n\n- '||array_to_string(v.forbidden_phrasings,E'\n- ')||E'\n\n','')||
coalesce('**Emoji policy.** '||v.emoji_policy||E'\n\n','')||
'## Lane'||E'\n\n'||
coalesce('**Primary domain:** '||l.primary_domain||E'\n\n','')||
coalesce('**Does:** '||array_to_string(l.does,', ')||E'\n\n','')||
coalesce('**Routes away:**'||E'\n\n- '||array_to_string(l.does_not,E'\n- ')||E'\n\n','')||
coalesce('**Suppression.** '||l.suppression_rules||E'\n\n','')||
'## Strengths'||E'\n\n'||
coalesce((SELECT string_agg('- **'||strength||'** — '||coalesce(description,''),E'\n' ORDER BY sort_order,strength) FROM persona_strength WHERE version_id=p_version_id),'')||E'\n\n'||
'## Tools'||E'\n\n'||
coalesce((SELECT string_agg('- `'||tool_name||'` — '||coalesce(purpose,''),E'\n' ORDER BY sort_order,tool_name) FROM persona_tool WHERE version_id=p_version_id),'')||E'\n\n'||
'<!-- ADAPTER SECTION (platform-specific) — filled by build agent under eval gate, NOT part of identity_signature. -->'||E'\n'
FROM persona_version pv
JOIN persona p ON p.agent_name=pv.agent_name
LEFT JOIN persona_character_bible b ON b.version_id=pv.id
LEFT JOIN persona_voice_contract v ON v.version_id=pv.id
LEFT JOIN persona_lane_contract l ON l.version_id=pv.id
WHERE pv.id=p_version_id;
$$;


--
-- Name: fn_run_retrieval_eval_fts(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_run_retrieval_eval_fts(p_tenant_id text DEFAULT 'omatic'::text, p_run_label text DEFAULT NULL::text, p_run_by text DEFAULT 'factory'::text) RETURNS TABLE(run_id bigint, case_id text, expected_found boolean, first_match_rank integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run_id bigint;
  v_case record;
  v_started timestamptz;
  v_returned jsonb;
  v_expected_found boolean;
  v_first_match integer;
  v_latency integer;
BEGIN
  INSERT INTO factory.retrieval_eval_runs (tenant_id, run_label, run_by, embedding_mode, notes)
  VALUES (p_tenant_id, p_run_label, p_run_by, 'fts_only', 'FTS-only retrieval eval using NULL::vector.')
  RETURNING retrieval_eval_runs.run_id INTO v_run_id;

  FOR v_case IN
    SELECT *
    FROM factory.retrieval_eval_cases
    WHERE tenant_id = p_tenant_id
      AND active = true
    ORDER BY case_id
  LOOP
    v_started := clock_timestamp();

    IF v_case.target_function = 'fn_search_semantic' THEN
      WITH results AS (
        SELECT row_number() OVER ()::int AS rank,
               jsonb_build_object('source_table', source_table, 'source_id', source_id) AS src
        FROM public.fn_search_semantic(v_case.query_text, NULL::vector, p_tenant_id, 10)
      ),
      matches AS (
        SELECT min(r.rank) AS first_match_rank
        FROM results r
        JOIN jsonb_array_elements(v_case.expected_sources) e(expected)
          ON r.src @> e.expected
      )
      SELECT COALESCE(jsonb_agg(src ORDER BY rank), '[]'::jsonb),
             EXISTS (SELECT 1 FROM matches m WHERE m.first_match_rank IS NOT NULL),
             (SELECT m.first_match_rank FROM matches m)
      INTO v_returned, v_expected_found, v_first_match
      FROM results;
    ELSE
      WITH results AS (
        SELECT row_number() OVER ()::int AS rank,
               jsonb_build_object('source_type', source_type, 'source_name', source_name, 'chunk_index', chunk_index) AS src
        FROM public.fn_search_documents(v_case.query_text, NULL::vector, p_tenant_id, 10)
      ),
      matches AS (
        SELECT min(r.rank) AS first_match_rank
        FROM results r
        JOIN jsonb_array_elements(v_case.expected_sources) e(expected)
          ON r.src @> e.expected
      )
      SELECT COALESCE(jsonb_agg(src ORDER BY rank), '[]'::jsonb),
             EXISTS (SELECT 1 FROM matches m WHERE m.first_match_rank IS NOT NULL),
             (SELECT m.first_match_rank FROM matches m)
      INTO v_returned, v_expected_found, v_first_match
      FROM results;
    END IF;

    v_latency := floor(extract(epoch FROM (clock_timestamp() - v_started)) * 1000)::int;

    INSERT INTO factory.retrieval_eval_results (
      run_id, case_id, top_k, returned_sources, expected_found, first_match_rank, latency_ms
    )
    VALUES (
      v_run_id, v_case.case_id, 10, COALESCE(v_returned, '[]'::jsonb),
      COALESCE(v_expected_found, false), v_first_match, v_latency
    );

    RETURN QUERY SELECT v_run_id, v_case.case_id, COALESCE(v_expected_found, false), v_first_match;
  END LOOP;

  UPDATE factory.retrieval_eval_runs
  SET completed_at = now()
  WHERE retrieval_eval_runs.run_id = v_run_id;
END;
$$;


--
-- Name: fn_search_documents(text, public.vector, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_search_documents(p_query_text text, p_query_vector public.vector, p_tenant_id text DEFAULT 'omatic'::text, p_limit integer DEFAULT 10) RETURNS TABLE(id integer, source_type text, source_name text, chunk_index integer, content text, fts_rank real, vec_distance real, combined_score real, embedding_stale boolean)
    LANGUAGE sql STABLE
    AS $$
  WITH query AS (
    SELECT plainto_tsquery('english', p_query_text) AS q
  ),
  fts AS (
    SELECT dc.id,
           ts_rank(dc.tsv, query.q)                              AS r,
           ROW_NUMBER() OVER (
             ORDER BY ts_rank(dc.tsv, query.q) DESC
           )                                                      AS rk
    FROM document_chunks dc, query
    WHERE dc.tenant_id = p_tenant_id
      AND dc.tsv @@ query.q
  ),
  vec_candidates AS (
    SELECT dc.id,
           dc.tenant_id,
           dc.embedding <=> p_query_vector                        AS d
    FROM document_chunks dc
    WHERE p_query_vector IS NOT NULL
      AND dc.embedding IS NOT NULL
    ORDER BY dc.embedding <=> p_query_vector
    LIMIT GREATEST(p_limit * 50, 200)
  ),
  vec AS (
    SELECT vc.id,
           vc.d,
           ROW_NUMBER() OVER (ORDER BY vc.d)                      AS rk
    FROM vec_candidates vc
    WHERE vc.tenant_id = p_tenant_id
    LIMIT p_limit * 4
  )
  SELECT dc.id,
         dc.source_type,
         dc.source_name,
         dc.chunk_index,
         dc.content,
         COALESCE(fts.r,  0)::real                               AS fts_rank,
         COALESCE(vec.d,  1)::real                               AS vec_distance,
         (COALESCE(1.0 / (60 + fts.rk), 0)
          + COALESCE(1.0 / (60 + vec.rk), 0))::real              AS combined_score,
         dc.embedding_stale
  FROM document_chunks dc
  LEFT JOIN fts ON fts.id = dc.id
  LEFT JOIN vec ON vec.id = dc.id
  WHERE dc.tenant_id = p_tenant_id
    AND (fts.id IS NOT NULL OR vec.id IS NOT NULL)
  ORDER BY combined_score DESC
  LIMIT p_limit;
$$;


--
-- Name: fn_search_semantic(text, public.vector, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_search_semantic(p_query_text text, p_query_vector public.vector, p_tenant_id text DEFAULT 'omatic'::text, p_limit integer DEFAULT 10) RETURNS TABLE(id bigint, source_table text, source_id text, entity_type text, summary_text text, fts_rank real, vec_distance real, combined_score real, embedding_stale boolean)
    LANGUAGE sql STABLE
    AS $$
  WITH query AS (
    SELECT plainto_tsquery('english', p_query_text) AS q
  ),
  fts AS (
    SELECT si.id,
           ts_rank(si.tsv, query.q)                              AS r,
           ROW_NUMBER() OVER (
             ORDER BY ts_rank(si.tsv, query.q) DESC
           )                                                      AS rk
    FROM semantic_index si, query
    WHERE si.tenant_id = p_tenant_id
      AND si.tsv @@ query.q
  ),
  vec_candidates AS (
    SELECT si.id,
           si.tenant_id,
           si.embedding <=> p_query_vector                        AS d
    FROM semantic_index si
    WHERE p_query_vector IS NOT NULL
      AND si.embedding IS NOT NULL
    ORDER BY si.embedding <=> p_query_vector
    LIMIT GREATEST(p_limit * 50, 200)
  ),
  vec AS (
    SELECT vc.id,
           vc.d,
           ROW_NUMBER() OVER (ORDER BY vc.d)                      AS rk
    FROM vec_candidates vc
    WHERE vc.tenant_id = p_tenant_id
    LIMIT p_limit * 4
  )
  SELECT si.id,
         si.source_table,
         si.source_id,
         si.entity_type,
         si.summary_text,
         COALESCE(fts.r,  0)::real                               AS fts_rank,
         COALESCE(vec.d,  1)::real                               AS vec_distance,
         (COALESCE(1.0 / (60 + fts.rk), 0)
          + COALESCE(1.0 / (60 + vec.rk), 0))::real              AS combined_score,
         si.embedding_stale
  FROM semantic_index si
  LEFT JOIN fts ON fts.id = si.id
  LEFT JOIN vec ON vec.id = si.id
  WHERE si.tenant_id = p_tenant_id
    AND (fts.id IS NOT NULL OR vec.id IS NOT NULL)
  ORDER BY combined_score DESC
  LIMIT p_limit;
$$;


--
-- Name: fn_seed_semantic_index(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_seed_semantic_index() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_entity text; v_summary text; v_source_id text; v_model text; v_tier text := 'operational';
BEGIN
  v_model := COALESCE((SELECT value #>> '{}' FROM factory_config WHERE key = 'openai_embedding_model' LIMIT 1), 'text-embedding-3-small');

  IF TG_TABLE_NAME = 'brand_messaging' THEN
    v_entity := 'brand'; v_source_id := NEW.id::text;
    v_summary := 'Brand '||COALESCE(NEW.category,'')||' ('||COALESCE(NEW.sub_type,'')||'): '||COALESCE(NEW.content,'');
    v_tier := CASE WHEN NEW.sub_type LIKE 'manifest-%' THEN 'sacred' ELSE 'canon' END;
  ELSIF TG_TABLE_NAME = 'project_knowledge' THEN
    v_entity := 'knowledge'; v_source_id := NEW.id::text;
    v_summary := COALESCE(NEW.knowledge_type,'')||' - '||COALESCE(NEW.title,'')||': '||COALESCE(NEW.detail,'');
    v_tier := 'canon';
  ELSIF TG_TABLE_NAME = 'tasks' THEN
    v_entity := 'task'; v_source_id := NEW.id::text;
    v_summary := 'Task '||COALESCE(NEW.category,'')||' - '||COALESCE(NEW.title,'')||': '||COALESCE(NEW.description,'');
    v_tier := 'operational';
  ELSIF TG_TABLE_NAME = 'decisions' THEN
    v_entity := 'decision'; v_source_id := NEW.id::text;
    v_summary := 'Decision '||COALESCE(NEW.title,'')||': '||COALESCE(NEW.decision,'');
    v_tier := 'canon';
  ELSIF TG_TABLE_NAME = 'known_rules' THEN
    v_entity := 'policy_rule'; v_source_id := NEW.id::text;
    v_summary := COALESCE(NEW.category,'')||' '||COALESCE(NEW.rule_type,'')||' '||COALESCE(NEW.applies_to,'')||' '||COALESCE(NEW.enforcement,'')||'. '||COALESCE(NEW.rule,'');
    v_tier := CASE WHEN NEW.enforcement='halt' THEN 'sacred' ELSE 'canon' END;
  ELSIF TG_TABLE_NAME = 'sop_registry' THEN
    v_entity := 'sop'; v_source_id := NEW.sop_id;
    v_summary := 'SOP '||COALESCE(NEW.sop_id,'')||' - '||COALESCE(NEW.title,'')||': '||COALESCE(NEW.summary,'');
    v_tier := 'canon';
  ELSIF TG_TABLE_NAME = 'agent_identity' THEN
    v_entity := 'agent'; v_source_id := NEW.agent_name;
    v_summary := 'Agent '||COALESCE(NEW.agent_name,'')||' ('||COALESCE(NEW.callsign,'')||', '||COALESCE(NEW.primary_domain,'')||'): '||COALESCE(NEW.voice_anchor,'');
    v_tier := 'canon';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO semantic_index (tenant_id, source_table, source_id, entity_type, summary_text, model_version, embedding_stale, authority_tier)
  VALUES (NEW.tenant_id, TG_TABLE_NAME, v_source_id, v_entity, v_summary, v_model, true, v_tier)
  ON CONFLICT (tenant_id, source_table, source_id) DO NOTHING;

  RETURN NEW;
END;
$$;


--
-- Name: fn_seed_session_mcp_status(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_seed_session_mcp_status(p_session_id integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_inserted INT;
  v_session_id INT;
  v_platform TEXT;
BEGIN
  v_session_id := COALESCE(p_session_id, (SELECT MAX(id) FROM factory_sessions));

  IF v_session_id IS NOT NULL THEN
    SELECT platform INTO v_platform
    FROM factory_sessions
    WHERE id = v_session_id;
  END IF;

  INSERT INTO session_mcp_status (
    session_id, connector_id, platform, probe_result,
    probe_note, fallback_active, probed_at
  )
  SELECT
    v_session_id,
    r.connector_id,
    COALESCE(v_platform, 'unknown'),
    -- Normalise mcp_registry.probe_status to the allowed probe_result values
    CASE
      WHEN r.probe_status IN ('connected', 'unavailable', 'blocked') THEN r.probe_status
      ELSE 'untested'
    END,
    CASE
      WHEN r.is_blocked THEN 'Blocked: ' || COALESCE(r.block_reason, 'no reason recorded')
      WHEN r.probe_status IS NULL OR r.probe_status NOT IN ('connected','unavailable','blocked')
        THEN 'No prior probe on record'
      ELSE NULL
    END,
    false,
    NOW()
  FROM mcp_registry r
  WHERE r.active = true
    AND (
      r.platform_availability IS NULL
      OR r.platform_availability = '{}'
      OR COALESCE(v_platform, 'unknown') = ANY(r.platform_availability)
    )
  ON CONFLICT (session_id, connector_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_memory; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.agent_memory (
    id integer NOT NULL,
    agent_name text NOT NULL,
    memory_type text NOT NULL,
    title text NOT NULL,
    content text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: agent_memory_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.agent_memory_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.agent_memory_id_seq OWNED BY brain.agent_memory.id;


--
-- Name: docling_registry; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.docling_registry (
    id integer NOT NULL,
    file_path text NOT NULL,
    category character varying(40) NOT NULL,
    description text,
    docling_required boolean DEFAULT false NOT NULL,
    scope character varying(40) DEFAULT 'omatic'::character varying,
    notes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: docling_registry_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.docling_registry_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: docling_registry_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.docling_registry_id_seq OWNED BY brain.docling_registry.id;


--
-- Name: document_chunks; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.document_chunks (
    id integer NOT NULL,
    source_type text NOT NULL,
    source_id integer,
    chunk_index integer NOT NULL,
    content text NOT NULL,
    token_count integer,
    created_at timestamp with time zone DEFAULT now(),
    source_name text,
    embedded_at timestamp with time zone,
    model_version text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    embedding public.vector(1536),
    embedding_stale boolean DEFAULT false NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, COALESCE(content, ''::text))) STORED
);


--
-- Name: COLUMN document_chunks.model_version; Type: COMMENT; Schema: brain; Owner: -
--

COMMENT ON COLUMN brain.document_chunks.model_version IS 'Embedding model used to generate this vector. e.g. nomic-embed-text, nomic-embed-text:v1.5';


--
-- Name: document_chunks_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.document_chunks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_chunks_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.document_chunks_id_seq OWNED BY brain.document_chunks.id;


--
-- Name: project_knowledge; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.project_knowledge (
    id integer NOT NULL,
    knowledge_type text NOT NULL,
    title text NOT NULL,
    detail text NOT NULL,
    tags text[],
    source text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    is_active boolean DEFAULT true,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT chk_knowledge_type CHECK ((knowledge_type = ANY (ARRAY['framework'::text, 'project-context'::text, 'design-standard'::text, 'operator-context'::text, 'product'::text, 'architecture'::text, 'process'::text])))
);


--
-- Name: TABLE project_knowledge; Type: COMMENT; Schema: brain; Owner: -
--

COMMENT ON TABLE brain.project_knowledge IS 'Contextual knowledge that does not fit SOPs, rules, or config. Queryable by knowledge_type. Replaces factory_memory pattern.';


--
-- Name: project_knowledge_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.project_knowledge_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_knowledge_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.project_knowledge_id_seq OWNED BY brain.project_knowledge.id;


--
-- Name: research; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.research (
    id integer NOT NULL,
    topic text NOT NULL,
    summary text NOT NULL,
    sources jsonb DEFAULT '[]'::jsonb,
    tags text[] DEFAULT '{}'::text[],
    collected_by text DEFAULT 'probot'::text NOT NULL,
    session_id integer,
    status text DEFAULT 'active'::text NOT NULL,
    superseded_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text, 'superseded'::text])))
);


--
-- Name: research_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.research_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: research_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.research_id_seq OWNED BY brain.research.id;


--
-- Name: semantic_index; Type: TABLE; Schema: brain; Owner: -
--

CREATE TABLE brain.semantic_index (
    id bigint NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    source_table text NOT NULL,
    source_id text NOT NULL,
    entity_type text NOT NULL,
    summary_text text NOT NULL,
    embedding public.vector(1536),
    model_version text,
    embedded_at timestamp with time zone,
    embedding_stale boolean DEFAULT false NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, COALESCE(summary_text, ''::text))) STORED,
    authority_tier text DEFAULT 'operational'::text,
    CONSTRAINT chk_authority_tier CHECK ((authority_tier = ANY (ARRAY['sacred'::text, 'canon'::text, 'operational'::text, 'experimental'::text, 'archived'::text, 'deprecated'::text])))
);


--
-- Name: semantic_index_id_seq; Type: SEQUENCE; Schema: brain; Owner: -
--

CREATE SEQUENCE brain.semantic_index_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: semantic_index_id_seq; Type: SEQUENCE OWNED BY; Schema: brain; Owner: -
--

ALTER SEQUENCE brain.semantic_index_id_seq OWNED BY brain.semantic_index.id;


--
-- Name: brand_assets; Type: TABLE; Schema: brand; Owner: -
--

CREATE TABLE brand.brand_assets (
    id integer NOT NULL,
    filename text NOT NULL,
    rel_path text NOT NULL,
    ext text,
    bytes integer,
    sha256 text,
    width integer,
    height integer,
    origin_folder text,
    is_master boolean,
    notes text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    indexed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brand_assets_id_seq; Type: SEQUENCE; Schema: brand; Owner: -
--

CREATE SEQUENCE brand.brand_assets_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: brand_assets_id_seq; Type: SEQUENCE OWNED BY; Schema: brand; Owner: -
--

ALTER SEQUENCE brand.brand_assets_id_seq OWNED BY brand.brand_assets.id;


--
-- Name: brand_messaging; Type: TABLE; Schema: brand; Owner: -
--

CREATE TABLE brand.brand_messaging (
    id integer NOT NULL,
    category text NOT NULL,
    sub_type text,
    stage text,
    persona text,
    content text NOT NULL,
    notes text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT chk_brand_category CHECK ((category = ANY (ARRAY['differentiator'::text, 'pitch'::text, 'consideration-pitch'::text, 'objection'::text, 'cta'::text, 'verbal-identity'::text, 'product-messaging'::text, 'origin-story'::text, 'brand-identity'::text])))
);


--
-- Name: TABLE brand_messaging; Type: COMMENT; Schema: brand; Owner: -
--

COMMENT ON TABLE brand.brand_messaging IS 'Brand intelligence — Brandy queries this before any brand writing. Source of truth for voice, positioning, and messaging.';


--
-- Name: brand_messaging_id_seq; Type: SEQUENCE; Schema: brand; Owner: -
--

CREATE SEQUENCE brand.brand_messaging_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: brand_messaging_id_seq; Type: SEQUENCE OWNED BY; Schema: brand; Owner: -
--

ALTER SEQUENCE brand.brand_messaging_id_seq OWNED BY brand.brand_messaging.id;


--
-- Name: content_staging; Type: TABLE; Schema: brand; Owner: -
--

CREATE TABLE brand.content_staging (
    id integer NOT NULL,
    title text NOT NULL,
    content_type text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    target_page_id integer,
    target_url text,
    assigned_to text,
    file_path text,
    summary text,
    research_id integer,
    session_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT content_staging_content_type_check CHECK ((content_type = ANY (ARRAY['article'::text, 'post'::text, 'page-copy'::text, 'blurb'::text, 'social'::text, 'email'::text]))),
    CONSTRAINT content_staging_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'staged'::text, 'approved'::text, 'published'::text, 'archived'::text])))
);


--
-- Name: content_staging_id_seq; Type: SEQUENCE; Schema: brand; Owner: -
--

CREATE SEQUENCE brand.content_staging_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: content_staging_id_seq; Type: SEQUENCE OWNED BY; Schema: brand; Owner: -
--

ALTER SEQUENCE brand.content_staging_id_seq OWNED BY brand.content_staging.id;


--
-- Name: agent_identity; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.agent_identity (
    agent_name character varying NOT NULL,
    callsign character varying NOT NULL,
    factory_type character varying NOT NULL,
    personality_tags text[] DEFAULT '{}'::text[] NOT NULL,
    tone_descriptor text NOT NULL,
    voice_anchor text,
    trigger_phrases text[] DEFAULT '{}'::text[] NOT NULL,
    primary_domain text NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_identity_factory_type_check CHECK (((factory_type)::text = ANY (ARRAY[('closed'::character varying)::text, ('standalone'::character varying)::text])))
);


--
-- Name: agent_state; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.agent_state (
    agent_name character varying(50) NOT NULL,
    role character varying(100),
    version character varying(20),
    state_sig integer,
    source_file text,
    status character varying(20),
    updated_at timestamp with time zone DEFAULT now(),
    factory character varying DEFAULT 'closed_factory'::character varying,
    installed_at timestamp with time zone,
    skill_file_path text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL
);


--
-- Name: decisions; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.decisions (
    id integer NOT NULL,
    decision_date date NOT NULL,
    category character varying(50) NOT NULL,
    title character varying(200) NOT NULL,
    decision text,
    rationale text,
    made_by character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    alternatives_rejected text,
    confidence text,
    dependencies text,
    downstream_effects text
);


--
-- Name: decisions_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.decisions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.decisions_id_seq OWNED BY factory.decisions.id;


--
-- Name: decommissioned_term_allowlist; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.decommissioned_term_allowlist (
    source_table text NOT NULL,
    source_id text NOT NULL,
    term text NOT NULL,
    reason text,
    allowed_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL
);


--
-- Name: decommissioned_terms; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.decommissioned_terms (
    term text NOT NULL,
    retired_in text NOT NULL,
    retired_at timestamp with time zone DEFAULT now() NOT NULL,
    notes text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL
);


--
-- Name: factory_agreements; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.factory_agreements (
    id integer NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    agent_name text NOT NULL,
    agreement_version text NOT NULL,
    effective_date date NOT NULL,
    required_rule_types text[] NOT NULL,
    enforcement_model text NOT NULL,
    llm_agnostic boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    retrieval_contract jsonb,
    CONSTRAINT factory_agreements_enforcement_model_check CHECK ((enforcement_model = ANY (ARRAY['halt_on_missing'::text, 'advisory_only'::text])))
);


--
-- Name: factory_agreements_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.factory_agreements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: factory_agreements_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.factory_agreements_id_seq OWNED BY factory.factory_agreements.id;


--
-- Name: factory_config; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.factory_config (
    key text NOT NULL,
    value jsonb NOT NULL,
    category text NOT NULL,
    notes text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text DEFAULT 'system'::text
);


--
-- Name: factory_lanes; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.factory_lanes (
    lane text NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    owner_agents text[] NOT NULL,
    reviewer_agent text,
    parallel_eligible boolean DEFAULT false NOT NULL,
    exclusive_resources text[] DEFAULT '{}'::text[] NOT NULL,
    notes text
);


--
-- Name: factory_sessions; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.factory_sessions (
    id integer NOT NULL,
    session_date date NOT NULL,
    platform character varying(50),
    session_type text,
    summary text,
    resume_notes text,
    created_at timestamp with time zone DEFAULT now(),
    agents_active text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL
);


--
-- Name: factory_sessions_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.factory_sessions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: factory_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.factory_sessions_id_seq OWNED BY factory.factory_sessions.id;


--
-- Name: known_rules; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.known_rules (
    id integer NOT NULL,
    category character varying(50) NOT NULL,
    rule text,
    created_at timestamp with time zone DEFAULT now(),
    source text DEFAULT 'session'::character varying,
    rule_type text,
    applies_to text,
    enforcement text,
    source_version text,
    llm_agnostic boolean DEFAULT true,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT chk_enforcement CHECK ((enforcement = ANY (ARRAY['advisory'::text, 'required'::text, 'halt'::text]))),
    CONSTRAINT chk_rule_type CHECK ((rule_type = ANY (ARRAY['routing'::text, 'voice'::text, 'behavior'::text, 'sop'::text, 'gate'::text, 'brand'::text, 'infra'::text])))
);


--
-- Name: known_rules_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.known_rules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: known_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.known_rules_id_seq OWNED BY factory.known_rules.id;


--
-- Name: mcp_registry; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.mcp_registry (
    id integer NOT NULL,
    connector_id text NOT NULL,
    display_name text NOT NULL,
    mcp_name text,
    description text,
    scope text,
    agent_primary text,
    always_probe boolean DEFAULT false,
    active boolean DEFAULT true,
    is_blocked boolean DEFAULT false,
    block_reason text,
    body_md text,
    probe_status text DEFAULT 'unknown'::text,
    last_probed_at timestamp with time zone,
    category text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    criticality text DEFAULT 'standard'::text NOT NULL,
    fallback_behavior text,
    platform_availability text[] DEFAULT ARRAY['cowork'::text] NOT NULL,
    tool_prefix text,
    tool_count integer,
    schema_hash text,
    last_audited_at timestamp with time zone,
    tools_json jsonb,
    CONSTRAINT mcp_registry_criticality_check CHECK ((criticality = ANY (ARRAY['critical'::text, 'standard'::text, 'enhancement'::text])))
);


--
-- Name: TABLE mcp_registry; Type: COMMENT; Schema: factory; Owner: -
--

COMMENT ON TABLE factory.mcp_registry IS 'Server connections — MCP connectors available to this factory. is_blocked=true means agents must never use this connector.';


--
-- Name: mcp_registry_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.mcp_registry_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mcp_registry_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.mcp_registry_id_seq OWNED BY factory.mcp_registry.id;


--
-- Name: rimmer_runs; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.rimmer_runs (
    id integer NOT NULL,
    run_date timestamp with time zone DEFAULT now() NOT NULL,
    model_tested text NOT NULL,
    agent_name text NOT NULL,
    layer integer NOT NULL,
    score numeric(5,2),
    pass boolean,
    criteria_results jsonb DEFAULT '{}'::jsonb NOT NULL,
    session_id integer,
    run_by text DEFAULT 'rimmer'::text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    factory_id text DEFAULT 'omatic'::text NOT NULL,
    factory_tenant text DEFAULT 'omatic'::text NOT NULL,
    run_mode text DEFAULT 'claude_code'::text NOT NULL,
    test_suite_version text DEFAULT '1.0.0'::text NOT NULL,
    agent_version text,
    agent_sig integer,
    CONSTRAINT rimmer_runs_layer_check CHECK ((layer = ANY (ARRAY[1, 2])))
);


--
-- Name: v_hud_agent_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_hud_agent_status AS
 WITH normalized AS (
         SELECT lower(rimmer_runs.agent_name) AS agent,
            rimmer_runs.layer,
            rimmer_runs.score,
            rimmer_runs.pass,
            rimmer_runs.factory_tenant,
            rimmer_runs.run_date,
            rimmer_runs.notes
           FROM factory.rimmer_runs
          WHERE (rimmer_runs.factory_tenant = 'omatic'::text)
        ), l1 AS (
         SELECT DISTINCT ON (normalized.agent) normalized.agent,
            normalized.score AS l1_score,
            normalized.pass AS l1_pass,
            normalized.notes AS l1_notes
           FROM normalized
          WHERE (normalized.layer = 1)
          ORDER BY normalized.agent, normalized.run_date DESC
        ), l2 AS (
         SELECT DISTINCT ON (normalized.agent) normalized.agent,
            normalized.score AS l2_score,
            normalized.pass AS l2_pass,
            normalized.notes AS l2_notes
           FROM normalized
          WHERE (normalized.layer = 2)
          ORDER BY normalized.agent, normalized.run_date DESC
        )
 SELECT COALESCE(l1.agent, l2.agent) AS agent_name,
    l1.l1_score,
    l1.l1_pass,
    l2.l2_score,
    l2.l2_pass,
        CASE
            WHEN ((l1.l1_pass = true) AND (l2.l2_pass = true)) THEN 'PRODUCTION_READY'::text
            WHEN ((l1.l1_pass = true) AND (l2.l2_pass IS NULL)) THEN 'L1_PASS_AWAITING_L2'::text
            WHEN (l1.l1_pass = false) THEN 'REWRITE_REQUIRED'::text
            WHEN ((l1.l1_pass IS NULL) AND (l2.l2_pass IS NULL)) THEN 'NOT_EVALUATED'::text
            ELSE 'DEFERRED'::text
        END AS readiness_tier,
    l1.l1_notes,
    l2.l2_notes
   FROM (l1
     FULL JOIN l2 ON ((l1.agent = l2.agent)));


--
-- Name: mv_agent_eval_status; Type: MATERIALIZED VIEW; Schema: factory; Owner: -
--

CREATE MATERIALIZED VIEW factory.mv_agent_eval_status AS
 SELECT agent_name,
    l1_score,
    l1_pass,
    l2_score,
    l2_pass,
    readiness_tier,
    l1_notes,
    l2_notes
   FROM public.v_hud_agent_status
  WITH NO DATA;


--
-- Name: tasks; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.tasks (
    id integer NOT NULL,
    category character varying(50),
    description text,
    status character varying(20) DEFAULT 'open'::character varying,
    owner character varying(50),
    ref_id character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    closed_at timestamp with time zone,
    priority integer DEFAULT 3,
    title character varying(120),
    blocked_by integer,
    updated_at timestamp with time zone DEFAULT now(),
    tenant_id text NOT NULL
);


--
-- Name: v_dashboard; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_dashboard AS
 SELECT ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE ((tasks.status)::text = 'open'::text)) AS open_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND (tasks.priority = 1))) AS critical,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND (tasks.priority = 2))) AS high,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND (tasks.priority = 3))) AS normal,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND (tasks.priority = 4))) AS low,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'SITE'::text))) AS site_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'BUILD'::text))) AS build_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'CONTENT'::text))) AS content_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'INFRA'::text))) AS infra_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'OPS'::text))) AS ops_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE (((tasks.status)::text = 'open'::text) AND ((tasks.category)::text = 'GATE'::text))) AS gate_tasks,
    ( SELECT count(*) AS count
           FROM factory.agent_state
          WHERE ((agent_state.status)::text = 'active'::text)) AS active_agents,
    ( SELECT count(*) AS count
           FROM factory.agent_state
          WHERE ((agent_state.status)::text = 'standalone'::text)) AS standalone_agents,
    ( SELECT factory_sessions.session_date
           FROM factory.factory_sessions
          ORDER BY factory_sessions.session_date DESC
         LIMIT 1) AS last_session_date,
    ( SELECT factory_sessions.platform
           FROM factory.factory_sessions
          ORDER BY factory_sessions.session_date DESC
         LIMIT 1) AS last_platform,
    ( SELECT factory_sessions.resume_notes
           FROM factory.factory_sessions
          ORDER BY factory_sessions.session_date DESC
         LIMIT 1) AS resume_notes;


--
-- Name: mv_dashboard; Type: MATERIALIZED VIEW; Schema: factory; Owner: -
--

CREATE MATERIALIZED VIEW factory.mv_dashboard AS
 SELECT open_tasks,
    critical,
    high,
    normal,
    low,
    site_tasks,
    build_tasks,
    content_tasks,
    infra_tasks,
    ops_tasks,
    gate_tasks,
    active_agents,
    standalone_agents,
    last_session_date,
    last_platform,
    resume_notes
   FROM public.v_dashboard
  WITH NO DATA;


--
-- Name: v_embedding_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_embedding_health AS
 SELECT 'semantic_index'::text AS tier,
    semantic_index.tenant_id,
    count(*) AS total_rows,
    count(*) FILTER (WHERE (semantic_index.embedding IS NOT NULL)) AS embedded,
    count(*) FILTER (WHERE (semantic_index.embedding IS NULL)) AS unembedded,
    count(*) FILTER (WHERE (semantic_index.embedding_stale = true)) AS stale,
    count(DISTINCT semantic_index.model_version) FILTER (WHERE (semantic_index.model_version IS NOT NULL)) AS distinct_models,
    min(semantic_index.embedded_at) AS oldest_embed,
    max(semantic_index.embedded_at) AS newest_embed
   FROM brain.semantic_index
  GROUP BY semantic_index.tenant_id
UNION ALL
 SELECT 'document_chunks'::text AS tier,
    document_chunks.tenant_id,
    count(*) AS total_rows,
    count(*) FILTER (WHERE (document_chunks.embedding IS NOT NULL)) AS embedded,
    count(*) FILTER (WHERE (document_chunks.embedding IS NULL)) AS unembedded,
    count(*) FILTER (WHERE (document_chunks.embedding_stale = true)) AS stale,
    count(DISTINCT document_chunks.model_version) FILTER (WHERE (document_chunks.model_version IS NOT NULL)) AS distinct_models,
    min(document_chunks.embedded_at) AS oldest_embed,
    max(document_chunks.embedded_at) AS newest_embed
   FROM brain.document_chunks
  GROUP BY document_chunks.tenant_id;


--
-- Name: mv_embedding_health; Type: MATERIALIZED VIEW; Schema: factory; Owner: -
--

CREATE MATERIALIZED VIEW factory.mv_embedding_health AS
 SELECT tier,
    tenant_id,
    total_rows,
    embedded,
    unembedded,
    stale,
    distinct_models,
    oldest_embed,
    newest_embed
   FROM public.v_embedding_health
  WITH NO DATA;


--
-- Name: sop_registry; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.sop_registry (
    sop_id text NOT NULL,
    title text NOT NULL,
    version text,
    owner text,
    trigger_condition text,
    trigger_phrases text[],
    summary text,
    full_body text,
    status text DEFAULT 'active'::text NOT NULL,
    merged_into text,
    file_path text,
    notes text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    domain text,
    CONSTRAINT sop_registry_domain_check CHECK ((domain = ANY (ARRAY['governance'::text, 'orchestration'::text, 'operations'::text, 'brand'::text, 'product-agents'::text, 'infrastructure'::text])))
);


--
-- Name: sop_steps; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.sop_steps (
    id integer NOT NULL,
    sop_id text NOT NULL,
    step_number integer NOT NULL,
    title text NOT NULL,
    content text NOT NULL,
    sql_snippet text,
    is_guard boolean DEFAULT false,
    halt_on_fail boolean DEFAULT false,
    tenant_id text DEFAULT 'omatic'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: v_factory_kernel_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_factory_kernel_health AS
 SELECT 'Factory Pro v3.1'::text AS standard,
    (to_regclass('factory.factory_config'::text) IS NOT NULL) AS server_config,
    (to_regclass('factory.known_rules'::text) IS NOT NULL) AS governance_rules,
    (to_regclass('factory.sop_registry'::text) IS NOT NULL) AS sop_registry,
    (to_regclass('factory.sop_steps'::text) IS NOT NULL) AS sop_steps,
    (to_regclass('factory.mcp_registry'::text) IS NOT NULL) AS server_connections,
    (to_regclass('factory.session_log'::text) IS NOT NULL) AS session_log,
    (to_regclass('brand.brand_messaging'::text) IS NOT NULL) AS brand_messaging,
    (to_regclass('brain.project_knowledge'::text) IS NOT NULL) AS project_knowledge,
    (to_regclass('factory.agent_state'::text) IS NOT NULL) AS agent_registry,
    (to_regclass('factory.factory_agreements'::text) IS NOT NULL) AS agent_agreements,
    ( SELECT count(*) AS count
           FROM factory.sop_registry
          WHERE ((sop_registry.tenant_id = 'omatic'::text) AND (sop_registry.status = 'active'::text))) AS active_sops,
    ( SELECT count(*) AS count
           FROM factory.sop_steps) AS sop_steps_total,
    ( SELECT count(*) AS count
           FROM factory.mcp_registry
          WHERE ((mcp_registry.tenant_id = 'omatic'::text) AND (mcp_registry.active = true))) AS active_connections,
    ( SELECT count(*) AS count
           FROM factory.mcp_registry
          WHERE ((mcp_registry.tenant_id = 'omatic'::text) AND (mcp_registry.is_blocked = true))) AS blocked_connections,
    ( SELECT count(*) AS count
           FROM factory.known_rules
          WHERE (known_rules.tenant_id = 'omatic'::text)) AS governance_rule_count,
    ( SELECT count(*) AS count
           FROM factory.factory_agreements
          WHERE (factory_agreements.tenant_id = 'omatic'::text)) AS agent_agreement_count,
    ( SELECT count(*) AS count
           FROM brand.brand_messaging
          WHERE (brand_messaging.tenant_id = 'omatic'::text)) AS brand_message_count,
    ( SELECT count(*) AS count
           FROM brain.project_knowledge
          WHERE ((project_knowledge.tenant_id = 'omatic'::text) AND (project_knowledge.is_active = true))) AS knowledge_item_count,
    ( SELECT count(*) AS count
           FROM factory.agent_state
          WHERE ((agent_state.tenant_id = 'omatic'::text) AND ((agent_state.status)::text = 'active'::text))) AS active_agents,
        CASE
            WHEN ((to_regclass('factory.sop_steps'::text) IS NOT NULL) AND (to_regclass('factory.mcp_registry'::text) IS NOT NULL) AND (to_regclass('brand.brand_messaging'::text) IS NOT NULL) AND (to_regclass('brain.project_knowledge'::text) IS NOT NULL)) THEN 'FACTORY PRO — COMPLETE'::text
            ELSE 'FACTORY PRO — INCOMPLETE'::text
        END AS kernel_status;


--
-- Name: mv_factory_kernel_health; Type: MATERIALIZED VIEW; Schema: factory; Owner: -
--

CREATE MATERIALIZED VIEW factory.mv_factory_kernel_health AS
 SELECT standard,
    server_config,
    governance_rules,
    sop_registry,
    sop_steps,
    server_connections,
    session_log,
    brand_messaging,
    project_knowledge,
    agent_registry,
    agent_agreements,
    active_sops,
    sop_steps_total,
    active_connections,
    blocked_connections,
    governance_rule_count,
    agent_agreement_count,
    brand_message_count,
    knowledge_item_count,
    active_agents,
    kernel_status
   FROM public.v_factory_kernel_health
  WITH NO DATA;


--
-- Name: v_knowledge_with_decommissioned_terms; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_knowledge_with_decommissioned_terms AS
 SELECT pk.id,
    pk.tenant_id,
    pk.knowledge_type,
    pk.title,
    "left"(pk.detail, 200) AS detail_preview,
    array_agg(dt.term ORDER BY dt.term) AS matched_terms,
    count(*) AS hit_count
   FROM (brain.project_knowledge pk
     JOIN factory.decommissioned_terms dt ON (((pk.tenant_id = dt.tenant_id) AND ((pk.detail ~~* (('%'::text || dt.term) || '%'::text)) OR (pk.title ~~* (('%'::text || dt.term) || '%'::text))) AND (NOT (EXISTS ( SELECT 1
           FROM factory.decommissioned_term_allowlist a
          WHERE ((a.tenant_id = pk.tenant_id) AND (a.source_table = 'project_knowledge'::text) AND (a.source_id = (pk.id)::text) AND (a.term = dt.term))))))))
  GROUP BY pk.id, pk.tenant_id, pk.knowledge_type, pk.title, pk.detail;


--
-- Name: v_rules_with_decommissioned_terms; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rules_with_decommissioned_terms AS
 SELECT kr.id,
    kr.tenant_id,
    kr.category,
    "left"(kr.rule, 200) AS rule_preview,
    array_agg(dt.term ORDER BY dt.term) AS matched_terms,
    count(*) AS hit_count
   FROM (factory.known_rules kr
     JOIN factory.decommissioned_terms dt ON (((kr.tenant_id = dt.tenant_id) AND (kr.rule ~~* (('%'::text || dt.term) || '%'::text)) AND (NOT (EXISTS ( SELECT 1
           FROM factory.decommissioned_term_allowlist a
          WHERE ((a.tenant_id = kr.tenant_id) AND (a.source_table = 'known_rules'::text) AND (a.source_id = (kr.id)::text) AND (a.term = dt.term))))))))
  GROUP BY kr.id, kr.tenant_id, kr.category, kr.rule;


--
-- Name: v_sops_with_decommissioned_terms; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sops_with_decommissioned_terms AS
 SELECT sr.sop_id,
    sr.tenant_id,
    sr.title,
    "left"(COALESCE(sr.summary, sr.full_body), 200) AS preview,
    array_agg(dt.term ORDER BY dt.term) AS matched_terms,
    count(*) AS hit_count
   FROM (factory.sop_registry sr
     JOIN factory.decommissioned_terms dt ON (((sr.tenant_id = dt.tenant_id) AND ((sr.title ~~* (('%'::text || dt.term) || '%'::text)) OR (sr.summary ~~* (('%'::text || dt.term) || '%'::text)) OR (sr.full_body ~~* (('%'::text || dt.term) || '%'::text))) AND (NOT (EXISTS ( SELECT 1
           FROM factory.decommissioned_term_allowlist a
          WHERE ((a.tenant_id = sr.tenant_id) AND (a.source_table = 'sop_registry'::text) AND (a.source_id = sr.sop_id) AND (a.term = dt.term))))))))
  WHERE (sr.status <> ALL (ARRAY['tombstoned'::text, 'deprecated'::text]))
  GROUP BY sr.sop_id, sr.tenant_id, sr.title, sr.summary, sr.full_body;


--
-- Name: v_startup_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_startup_summary AS
 SELECT id AS last_session_id,
    session_date,
    platform,
    session_type,
    resume_notes,
    ( SELECT jsonb_object_agg(t.category, t.cnt) AS jsonb_object_agg
           FROM ( SELECT tasks.category,
                    count(*) AS cnt
                   FROM factory.tasks
                  WHERE ((tasks.status)::text = 'open'::text)
                  GROUP BY tasks.category
                  ORDER BY tasks.category) t) AS open_tasks,
    ( SELECT count(*) AS count
           FROM factory.tasks
          WHERE ((tasks.status)::text = 'open'::text)) AS open_task_total,
    ( SELECT jsonb_agg(jsonb_build_object('id', p.id, 'title', p.title, 'category', p.category, 'owner', p.owner) ORDER BY p.category, p.id) AS jsonb_agg
           FROM factory.tasks p
          WHERE (((p.status)::text = 'open'::text) AND (p.priority = 1))) AS p1_tasks,
    ( SELECT jsonb_agg(jsonb_build_object('name', agent_state.agent_name, 'version', agent_state.version, 'sig', agent_state.state_sig, 'status', agent_state.status) ORDER BY agent_state.status, agent_state.agent_name) AS jsonb_agg
           FROM factory.agent_state) AS agents,
    ( SELECT jsonb_object_agg(h.tier, jsonb_build_object('total', h.total_rows, 'embedded', h.embedded, 'stale', h.stale, 'unembedded', h.unembedded)) AS jsonb_object_agg
           FROM public.v_embedding_health h
          WHERE (h.tenant_id = 'omatic'::text)) AS embedding_health,
    jsonb_build_object('rules', ( SELECT count(*) AS count
           FROM public.v_rules_with_decommissioned_terms
          WHERE (v_rules_with_decommissioned_terms.tenant_id = 'omatic'::text)), 'knowledge', ( SELECT count(*) AS count
           FROM public.v_knowledge_with_decommissioned_terms
          WHERE (v_knowledge_with_decommissioned_terms.tenant_id = 'omatic'::text)), 'sops', ( SELECT count(*) AS count
           FROM public.v_sops_with_decommissioned_terms
          WHERE (v_sops_with_decommissioned_terms.tenant_id = 'omatic'::text))) AS decommissioned_terms,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('sop_id', sr.sop_id, 'title', sr.title, 'summary', sr.summary, 'trigger_phrases', sr.trigger_phrases) ORDER BY sr.sop_id), '[]'::jsonb) AS "coalesce"
           FROM factory.sop_registry sr
          WHERE ((sr.tenant_id = 'omatic'::text) AND (sr.status = 'active'::text))) AS sop_index,
    jsonb_build_object('active_rule_count', ( SELECT count(*) AS count
           FROM factory.known_rules
          WHERE (known_rules.tenant_id = 'omatic'::text)), 'rule_count_target', 21, 'combined_governance_target', 28, 'rule_type_sop_count', ( SELECT count(*) AS count
           FROM factory.known_rules
          WHERE ((known_rules.tenant_id = 'omatic'::text) AND (known_rules.rule_type = 'sop'::text))), 'agreement_required_sop_count', ( SELECT count(*) AS count
           FROM factory.factory_agreements
          WHERE ((factory_agreements.tenant_id = 'omatic'::text) AND ('sop'::text = ANY (factory_agreements.required_rule_types)))), 'active_sop_count', ( SELECT count(*) AS count
           FROM factory.sop_registry
          WHERE ((sop_registry.tenant_id = 'omatic'::text) AND (sop_registry.status = 'active'::text))), 'missing_sop_trigger_count', ( SELECT count(*) AS count
           FROM factory.sop_registry
          WHERE ((sop_registry.tenant_id = 'omatic'::text) AND (sop_registry.status = 'active'::text) AND ((sop_registry.trigger_phrases IS NULL) OR (cardinality(sop_registry.trigger_phrases) = 0)))), 'dead_sop_reference_count', ( SELECT count(*) AS count
           FROM (( SELECT kr.id AS rule_id,
                    m.m[1] AS sop_ref
                   FROM (factory.known_rules kr
                     CROSS JOIN LATERAL regexp_matches(kr.rule, '(SOP-[0-9]+)'::text, 'g'::text) m(m))
                  WHERE (kr.tenant_id = 'omatic'::text)) refs
             LEFT JOIN factory.sop_registry sr ON (((sr.tenant_id = 'omatic'::text) AND ((sr.sop_id = refs.sop_ref) OR (sr.title ~~* (('%'::text || refs.sop_ref) || '%'::text))))))
          WHERE ((sr.sop_id IS NULL) OR (sr.status <> 'active'::text)))) AS governance_health
   FROM factory.factory_sessions fs
  WHERE (id = ( SELECT max(factory_sessions.id) AS max
           FROM factory.factory_sessions));


--
-- Name: mv_startup_snapshot; Type: MATERIALIZED VIEW; Schema: factory; Owner: -
--

CREATE MATERIALIZED VIEW factory.mv_startup_snapshot AS
 SELECT last_session_id,
    session_date,
    platform,
    session_type,
    resume_notes,
    open_tasks,
    open_task_total,
    p1_tasks,
    agents,
    embedding_health,
    decommissioned_terms
   FROM public.v_startup_summary
  WITH NO DATA;


--
-- Name: persona; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona (
    agent_name character varying NOT NULL,
    callsign character varying NOT NULL,
    factory_type character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    current_version integer,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: persona_archetype; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_archetype (
    id integer NOT NULL,
    version_id integer NOT NULL,
    layer character varying NOT NULL,
    archetype_name character varying NOT NULL,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT persona_archetype_layer_check CHECK (((layer)::text = ANY ((ARRAY['primary'::character varying, 'character_flavor'::character varying, 'operational_mode'::character varying, 'crisis_mode'::character varying, 'deep_function'::character varying, 'ethic'::character varying])::text[])))
);


--
-- Name: persona_archetype_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_archetype_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_archetype_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_archetype_id_seq OWNED BY factory.persona_archetype.id;


--
-- Name: persona_asset; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_asset (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    asset_type character varying NOT NULL,
    variant character varying,
    path text NOT NULL,
    format character varying,
    is_primary boolean DEFAULT false NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT persona_asset_asset_type_check CHECK (((asset_type)::text = ANY ((ARRAY['thumbnail'::character varying, 'badge'::character varying, 'icon'::character varying, 'full_body'::character varying, 'wordmark'::character varying])::text[])))
);


--
-- Name: persona_asset_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_asset_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_asset_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_asset_id_seq OWNED BY factory.persona_asset.id;


--
-- Name: persona_build; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_build (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    persona_version integer NOT NULL,
    identity_signature text NOT NULL,
    identity_version integer,
    template_id character varying,
    template_version character varying,
    target_type character varying NOT NULL,
    target_factory text,
    output_checksum text,
    output_bytes integer,
    reason text,
    built_by character varying,
    built_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    CONSTRAINT persona_build_target_type_check CHECK (((target_type)::text = ANY ((ARRAY['l1_skill'::character varying, 'plugin_skill'::character varying, 'gpt'::character varying, 'l2_agent'::character varying, 'roster_card'::character varying, 'voice_avatar'::character varying])::text[])))
);


--
-- Name: TABLE persona_build; Type: COMMENT; Schema: factory; Owner: -
--

COMMENT ON TABLE factory.persona_build IS 'Append-only build lockfile. One row per render. Never UPDATE/DELETE.';


--
-- Name: persona_build_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_build_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_build_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_build_id_seq OWNED BY factory.persona_build.id;


--
-- Name: persona_character_bible; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_character_bible (
    id integer NOT NULL,
    version_id integer NOT NULL,
    backstory text,
    personality text,
    traits text[] DEFAULT '{}'::text[] NOT NULL,
    character_depth text,
    evolution_history text,
    emoji character varying,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    archetype text,
    humor text,
    seriousness_boundary text
);


--
-- Name: persona_character_bible_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_character_bible_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_character_bible_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_character_bible_id_seq OWNED BY factory.persona_character_bible.id;


--
-- Name: persona_character_dimension; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_character_dimension (
    id integer NOT NULL,
    version_id integer NOT NULL,
    dimension character varying NOT NULL,
    content text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: persona_character_dimension_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_character_dimension_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_character_dimension_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_character_dimension_id_seq OWNED BY factory.persona_character_dimension.id;


--
-- Name: persona_drift_check; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_drift_check (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    version_id integer,
    export_target_id integer,
    check_type character varying,
    result character varying DEFAULT 'untested'::character varying NOT NULL,
    drift_score numeric,
    detail text,
    checked_by character varying,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT persona_drift_check_result_check CHECK (((result)::text = ANY ((ARRAY['pass'::character varying, 'warn'::character varying, 'fail'::character varying, 'untested'::character varying])::text[])))
);


--
-- Name: persona_drift_check_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_drift_check_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_drift_check_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_drift_check_id_seq OWNED BY factory.persona_drift_check.id;


--
-- Name: persona_eval_criteria; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_eval_criteria (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    criterion character varying NOT NULL,
    assertion text NOT NULL,
    severity character varying DEFAULT 'blocker'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT persona_eval_criteria_severity_check CHECK (((severity)::text = ANY ((ARRAY['blocker'::character varying, 'warn'::character varying])::text[])))
);


--
-- Name: persona_eval_criteria_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_eval_criteria_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_eval_criteria_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_eval_criteria_id_seq OWNED BY factory.persona_eval_criteria.id;


--
-- Name: persona_export_target; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_export_target (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    target_type character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    generated_from_version integer,
    artifact_path text,
    checksum text,
    last_export_at timestamp with time zone,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT persona_export_target_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'generated'::character varying, 'published'::character varying, 'stale'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT persona_export_target_target_type_check CHECK (((target_type)::text = ANY ((ARRAY['l1_skill'::character varying, 'plugin_skill'::character varying, 'gpt'::character varying, 'l2_agent'::character varying, 'roster_card'::character varying, 'voice_avatar'::character varying])::text[])))
);


--
-- Name: persona_export_target_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_export_target_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_export_target_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_export_target_id_seq OWNED BY factory.persona_export_target.id;


--
-- Name: persona_lane_contract; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_lane_contract (
    id integer NOT NULL,
    version_id integer NOT NULL,
    primary_domain text,
    does text[] DEFAULT '{}'::text[] NOT NULL,
    does_not text[] DEFAULT '{}'::text[] NOT NULL,
    handoffs jsonb DEFAULT '{}'::jsonb NOT NULL,
    suppression_rules text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: persona_lane_contract_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_lane_contract_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_lane_contract_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_lane_contract_id_seq OWNED BY factory.persona_lane_contract.id;


--
-- Name: persona_provenance; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_provenance (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    version_id integer,
    source_type character varying,
    source_path text,
    derived_from text,
    migration_note text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: persona_provenance_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_provenance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_provenance_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_provenance_id_seq OWNED BY factory.persona_provenance.id;


--
-- Name: persona_strength; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_strength (
    id integer NOT NULL,
    version_id integer NOT NULL,
    strength character varying NOT NULL,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: persona_strength_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_strength_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_strength_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_strength_id_seq OWNED BY factory.persona_strength.id;


--
-- Name: persona_tool; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_tool (
    id integer NOT NULL,
    version_id integer NOT NULL,
    tool_name character varying NOT NULL,
    purpose text,
    category character varying,
    sort_order integer DEFAULT 0 NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    platform text[] DEFAULT '{all}'::text[] NOT NULL
);


--
-- Name: persona_tool_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_tool_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_tool_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_tool_id_seq OWNED BY factory.persona_tool.id;


--
-- Name: persona_version; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_version (
    id integer NOT NULL,
    agent_name character varying NOT NULL,
    version integer NOT NULL,
    review_status character varying DEFAULT 'draft'::character varying NOT NULL,
    role character varying,
    one_liner text,
    summary text,
    made_by character varying,
    source_skill_version character varying,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    trigger_phrases text[] DEFAULT '{}'::text[] NOT NULL,
    identity_signature text,
    identity_version integer,
    CONSTRAINT persona_version_review_status_check CHECK (((review_status)::text = ANY ((ARRAY['draft'::character varying, 'in_review'::character varying, 'approved'::character varying, 'published'::character varying, 'superseded'::character varying])::text[])))
);


--
-- Name: persona_version_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_version_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_version_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_version_id_seq OWNED BY factory.persona_version.id;


--
-- Name: persona_voice_contract; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.persona_voice_contract (
    id integer NOT NULL,
    version_id integer NOT NULL,
    opening_convention text,
    register text,
    voice_anchors text[] DEFAULT '{}'::text[] NOT NULL,
    forbidden_phrasings text[] DEFAULT '{}'::text[] NOT NULL,
    sample_lines text[] DEFAULT '{}'::text[] NOT NULL,
    emoji_policy text,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    voice_texture text
);


--
-- Name: persona_voice_contract_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.persona_voice_contract_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: persona_voice_contract_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.persona_voice_contract_id_seq OWNED BY factory.persona_voice_contract.id;


--
-- Name: process_changelog; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.process_changelog (
    id bigint NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    changed_by text,
    change_type text NOT NULL,
    summary text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: process_changelog_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.process_changelog_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: process_changelog_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.process_changelog_id_seq OWNED BY factory.process_changelog.id;


--
-- Name: retrieval_eval_cases; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.retrieval_eval_cases (
    case_id text NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    query_text text NOT NULL,
    target_function text NOT NULL,
    expected_sources jsonb DEFAULT '[]'::jsonb NOT NULL,
    notes text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retrieval_eval_cases_expected_sources_array CHECK ((jsonb_typeof(expected_sources) = 'array'::text)),
    CONSTRAINT retrieval_eval_cases_target_function_check CHECK ((target_function = ANY (ARRAY['fn_search_semantic'::text, 'fn_search_documents'::text])))
);


--
-- Name: retrieval_eval_results; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.retrieval_eval_results (
    result_id bigint NOT NULL,
    run_id bigint NOT NULL,
    case_id text NOT NULL,
    top_k integer DEFAULT 10 NOT NULL,
    returned_sources jsonb DEFAULT '[]'::jsonb NOT NULL,
    expected_found boolean DEFAULT false NOT NULL,
    first_match_rank integer,
    latency_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retrieval_eval_results_first_match_positive CHECK (((first_match_rank IS NULL) OR (first_match_rank > 0))),
    CONSTRAINT retrieval_eval_results_latency_nonnegative CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
    CONSTRAINT retrieval_eval_results_returned_sources_array CHECK ((jsonb_typeof(returned_sources) = 'array'::text)),
    CONSTRAINT retrieval_eval_results_top_k_check CHECK ((top_k > 0))
);


--
-- Name: retrieval_eval_results_result_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.retrieval_eval_results_result_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: retrieval_eval_results_result_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.retrieval_eval_results_result_id_seq OWNED BY factory.retrieval_eval_results.result_id;


--
-- Name: retrieval_eval_runs; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.retrieval_eval_runs (
    run_id bigint NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    run_label text,
    run_by text,
    embedding_mode text DEFAULT 'fts_only'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    notes text,
    CONSTRAINT retrieval_eval_runs_embedding_mode_check CHECK ((embedding_mode = ANY (ARRAY['fts_only'::text, 'hybrid'::text])))
);


--
-- Name: retrieval_eval_runs_run_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.retrieval_eval_runs_run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: retrieval_eval_runs_run_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.retrieval_eval_runs_run_id_seq OWNED BY factory.retrieval_eval_runs.run_id;


--
-- Name: retrieval_events; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.retrieval_events (
    id bigint NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    caller text,
    search_function text NOT NULL,
    query_text text NOT NULL,
    used_vector boolean NOT NULL,
    result_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    latency_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT retrieval_events_latency_nonnegative CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
    CONSTRAINT retrieval_events_result_ids_array CHECK ((jsonb_typeof(result_ids) = 'array'::text))
);


--
-- Name: retrieval_events_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.retrieval_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: retrieval_events_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.retrieval_events_id_seq OWNED BY factory.retrieval_events.id;


--
-- Name: rimmer_runs_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.rimmer_runs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rimmer_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.rimmer_runs_id_seq OWNED BY factory.rimmer_runs.id;


--
-- Name: rimmer_test_suite; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.rimmer_test_suite (
    id integer NOT NULL,
    agent_name text NOT NULL,
    factory_id text,
    factory_tenant text NOT NULL,
    sample_label text NOT NULL,
    sample_source text,
    trigger_used text,
    response_summary text,
    dimension text,
    quality text,
    promoted_by text,
    promoted_date date,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT rimmer_test_suite_quality_check CHECK ((quality = ANY (ARRAY['gold'::text, 'silver'::text, 'bronze'::text])))
);


--
-- Name: rimmer_test_suite_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.rimmer_test_suite_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rimmer_test_suite_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.rimmer_test_suite_id_seq OWNED BY factory.rimmer_test_suite.id;


--
-- Name: session_log; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.session_log (
    id integer NOT NULL,
    session_date date NOT NULL,
    session_id character varying(100),
    platform character varying(50),
    agent character varying(50),
    event_type character varying(50),
    detail text,
    created_at timestamp with time zone DEFAULT now(),
    tenant_id text DEFAULT 'omatic'::text,
    CONSTRAINT session_log_event_type_check CHECK (((event_type)::text = ANY (ARRAY['session_open'::text, 'session_close'::text, 'agent_handoff'::text, 'brand_review_pending'::text, 'brand_approved'::text, 'mcp_failure'::text, 'connector_blind_use'::text, 'task_opened'::text, 'task_closed'::text, 'sig_updated'::text, 'decision_logged'::text, 'file_write'::text, 'operator_decision_required'::text, 'brain_search'::text])))
);


--
-- Name: session_log_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.session_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: session_log_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.session_log_id_seq OWNED BY factory.session_log.id;


--
-- Name: session_mcp_status; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.session_mcp_status (
    id integer NOT NULL,
    session_id integer,
    connector_id text NOT NULL,
    platform text NOT NULL,
    probe_result text NOT NULL,
    probe_note text,
    fallback_active boolean DEFAULT false NOT NULL,
    probed_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    CONSTRAINT session_mcp_status_probe_result_check CHECK ((probe_result = ANY (ARRAY['connected'::text, 'unavailable'::text, 'blocked'::text, 'untested'::text])))
);


--
-- Name: session_mcp_status_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.session_mcp_status_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: session_mcp_status_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.session_mcp_status_id_seq OWNED BY factory.session_mcp_status.id;


--
-- Name: sig_log; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.sig_log (
    id integer NOT NULL,
    log_date date NOT NULL,
    agent_name character varying(50),
    old_sig integer,
    new_sig integer,
    reason text,
    created_at timestamp with time zone DEFAULT now(),
    old_version character varying(20),
    new_version character varying(20)
);


--
-- Name: sig_log_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.sig_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sig_log_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.sig_log_id_seq OWNED BY factory.sig_log.id;


--
-- Name: sop_steps_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.sop_steps_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sop_steps_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.sop_steps_id_seq OWNED BY factory.sop_steps.id;


--
-- Name: tasks_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.tasks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.tasks_id_seq OWNED BY factory.tasks.id;


--
-- Name: work_claims; Type: TABLE; Schema: factory; Owner: -
--

CREATE TABLE factory.work_claims (
    id integer NOT NULL,
    tenant_id text DEFAULT 'omatic'::text NOT NULL,
    resource_type text NOT NULL,
    resource_id text NOT NULL,
    claimed_by text NOT NULL,
    session_id text,
    claimed_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    released_at timestamp with time zone,
    status text DEFAULT 'active'::text NOT NULL,
    factory_id text DEFAULT 'omatic'::text NOT NULL,
    platform text,
    claim_note text,
    released_by text,
    CONSTRAINT work_claims_status_check CHECK ((status = ANY (ARRAY['active'::text, 'released'::text, 'expired'::text])))
);


--
-- Name: work_claims_id_seq; Type: SEQUENCE; Schema: factory; Owner: -
--

CREATE SEQUENCE factory.work_claims_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_claims_id_seq; Type: SEQUENCE OWNED BY; Schema: factory; Owner: -
--

ALTER SEQUENCE factory.work_claims_id_seq OWNED BY factory.work_claims.id;


--
-- Name: factory_lanes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.factory_lanes AS
 SELECT lane,
    tenant_id,
    owner_agents,
    reviewer_agent,
    parallel_eligible,
    exclusive_resources,
    notes
   FROM factory.factory_lanes;


--
-- Name: v_actionable_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_actionable_tasks AS
 SELECT id,
    priority,
    category,
    owner,
    title,
    ref_id
   FROM factory.tasks t
  WHERE (((status)::text = 'open'::text) AND ((blocked_by IS NULL) OR (EXISTS ( SELECT 1
           FROM factory.tasks b
          WHERE ((b.id = t.blocked_by) AND ((b.status)::text = 'closed'::text))))))
  ORDER BY priority, category, id;


--
-- Name: v_agent_agreement; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_agent_agreement AS
 WITH agreement_base AS (
         SELECT fa.agent_name,
            fa.agreement_version,
            fa.enforcement_model,
            fa.required_rule_types,
            count(kr.id) AS loaded_rules,
            fa.tenant_id
           FROM (factory.factory_agreements fa
             LEFT JOIN factory.known_rules kr ON (((kr.tenant_id = fa.tenant_id) AND ((kr.applies_to = fa.agent_name) OR (kr.applies_to = 'all'::text) OR (kr.applies_to = 'all-agents'::text) OR (fa.agent_name = ANY (string_to_array(TRIM(BOTH '{}'::text FROM kr.applies_to), ','::text)))))))
          GROUP BY fa.agent_name, fa.agreement_version, fa.enforcement_model, fa.required_rule_types, fa.tenant_id
        ), agreement_missing AS (
         SELECT ab.agent_name,
            ab.agreement_version,
            ab.enforcement_model,
            ab.required_rule_types,
            ab.loaded_rules,
            ab.tenant_id,
            ARRAY( SELECT required_type.required_type
                   FROM unnest(ab.required_rule_types) required_type(required_type)
                  WHERE (NOT (EXISTS ( SELECT 1
                           FROM factory.known_rules kr
                          WHERE ((kr.tenant_id = ab.tenant_id) AND (kr.rule_type = required_type.required_type) AND ((kr.applies_to = ab.agent_name) OR (kr.applies_to = 'all'::text) OR (kr.applies_to = 'all-agents'::text) OR (ab.agent_name = ANY (string_to_array(TRIM(BOTH '{}'::text FROM kr.applies_to), ','::text))))))))) AS missing_rule_types
           FROM agreement_base ab
        )
 SELECT agent_name,
    agreement_version,
    enforcement_model,
    required_rule_types,
    loaded_rules,
    tenant_id,
    missing_rule_types,
        CASE
            WHEN (cardinality(missing_rule_types) = 0) THEN 'READY'::text
            ELSE 'WARN_MISSING_RULE_TYPES'::text
        END AS status_label
   FROM agreement_missing;


--
-- Name: v_agent_roster; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_agent_roster AS
 SELECT agent_name,
    factory,
    status,
    role,
    version,
    state_sig,
    source_file,
    (updated_at)::date AS last_updated
   FROM factory.agent_state
  ORDER BY
        CASE factory
            WHEN 'closed_factory'::text THEN 1
            WHEN 'standalone'::text THEN 2
            ELSE 3
        END, agent_name;


--
-- Name: v_agent_rules_exploded; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_agent_rules_exploded AS
 SELECT kr.id,
    kr.tenant_id,
    TRIM(BOTH FROM agent_token.name) AS agent_name,
    kr.rule,
    kr.rule_type,
    kr.enforcement,
    kr.category,
    kr.applies_to AS original_applies_to
   FROM (factory.known_rules kr
     CROSS JOIN LATERAL ( SELECT unnest(
                CASE
                    WHEN (kr.applies_to = ANY (ARRAY['all'::text, 'all-agents'::text])) THEN ARRAY['probot'::text, 'brandy'::text, 'carver'::text, 'monet'::text, 'fred'::text, 'data'::text, 'smith'::text, 'jake'::text, 'jo'::text, 'jay'::text, 'pixel'::text, 'tim'::text]
                    ELSE string_to_array(TRIM(BOTH '{}'::text FROM kr.applies_to), ','::text)
                END) AS name) agent_token);


--
-- Name: v_agreement_rule_coverage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_agreement_rule_coverage AS
 SELECT fa.agent_name,
    fa.agreement_version,
    rt.rule_type,
    count(are.id) AS rule_count,
        CASE
            WHEN (count(are.id) = 0) THEN 'GAP'::text
            ELSE 'COVERED'::text
        END AS coverage_status
   FROM ((factory.factory_agreements fa
     CROSS JOIN LATERAL unnest(fa.required_rule_types) rt(rule_type))
     LEFT JOIN public.v_agent_rules_exploded are ON (((are.rule_type = rt.rule_type) AND (are.agent_name = fa.agent_name) AND (are.tenant_id = fa.tenant_id))))
  GROUP BY fa.agent_name, fa.agreement_version, rt.rule_type
  ORDER BY fa.agent_name, rt.rule_type;


--
-- Name: v_blocked_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_blocked_tasks AS
 SELECT t.id,
    t.priority,
    t.category,
    t.title AS blocked_task,
    b.id AS blocker_id,
    b.title AS blocker_title,
    b.status AS blocker_status
   FROM (factory.tasks t
     JOIN factory.tasks b ON ((t.blocked_by = b.id)))
  WHERE ((t.status)::text = 'open'::text)
  ORDER BY t.priority, t.id;


--
-- Name: v_brain_usage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_brain_usage AS
 SELECT tenant_id,
    session_id,
    count(*) FILTER (WHERE ((event_type)::text = 'brain_search'::text)) AS brain_searches,
    count(*) FILTER (WHERE ((event_type)::text = 'session_open'::text)) AS session_opens,
    max(created_at) FILTER (WHERE ((event_type)::text = 'brain_search'::text)) AS last_brain_search,
        CASE
            WHEN (count(*) FILTER (WHERE ((event_type)::text = 'brain_search'::text)) = 0) THEN 'dark'::text
            ELSE 'active'::text
        END AS brain_status
   FROM factory.session_log sl
  GROUP BY tenant_id, session_id
  ORDER BY session_id DESC;


--
-- Name: v_brand_soul; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_brand_soul AS
 SELECT 'doctrine'::text AS layer,
    document_chunks.source_name AS source,
    document_chunks.chunk_index AS ord,
    document_chunks.content
   FROM brain.document_chunks
  WHERE ((document_chunks.tenant_id = 'omatic'::text) AND (document_chunks.source_type = 'brand-doctrine'::text))
UNION ALL
 SELECT 'distilled'::text AS layer,
    ((brand_messaging.category || '/'::text) || brand_messaging.sub_type) AS source,
    brand_messaging.id AS ord,
    brand_messaging.content
   FROM brand.brand_messaging
  WHERE ((brand_messaging.tenant_id = 'omatic'::text) AND ((brand_messaging.category = ANY (ARRAY['origin-story'::text, 'brand-identity'::text])) OR (brand_messaging.sub_type = ANY (ARRAY['voice-canon'::text, 'sideways-language'::text, 'human-cyber-work-teams'::text, 'closing-line'::text, 'hero-claim'::text]))))
  ORDER BY 1, 2, 3;


--
-- Name: VIEW v_brand_soul; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.v_brand_soul IS 'The soul of O-Matic in one query. Doctrine layer = verbatim-faithful chunks of the Factory 2.0 letter and Golden Era Answers (sacred tier). Distilled layer = operational brand_messaging rows. SELECT * FROM v_brand_soul = pour it in. Verbatim masters live in brand/*.md on disk.';


--
-- Name: v_content_pipeline; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_content_pipeline AS
 SELECT id,
    title,
    content_type,
    status,
    assigned_to,
    target_page_id,
    (file_path IS NOT NULL) AS has_file,
    (created_at)::date AS created_date,
    (published_at)::date AS published_date
   FROM brand.content_staging
  WHERE (status <> 'archived'::text)
  ORDER BY
        CASE status
            WHEN 'approved'::text THEN 1
            WHEN 'staged'::text THEN 2
            WHEN 'draft'::text THEN 3
            WHEN 'published'::text THEN 4
            ELSE NULL::integer
        END, created_at DESC;


--
-- Name: v_decisions_log; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_decisions_log AS
 SELECT decision_date,
    category,
    title,
    decision,
    rationale,
    made_by
   FROM factory.decisions
  ORDER BY decision_date DESC, id DESC;


--
-- Name: v_docling_registry; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_docling_registry AS
 SELECT category,
    count(*) AS file_count,
    sum(
        CASE
            WHEN docling_required THEN 1
            ELSE 0
        END) AS needs_conversion
   FROM brain.docling_registry
  GROUP BY category
  ORDER BY category;


--
-- Name: v_factory_config; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_factory_config AS
 SELECT key,
    category,
    value,
    notes,
    updated_at,
    updated_by
   FROM factory.factory_config
  WHERE (tenant_id = 'omatic'::text)
  ORDER BY category, key;


--
-- Name: v_halt_rules_by_agent; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_halt_rules_by_agent AS
 SELECT agent_name,
    tenant_id,
    count(*) AS halt_rule_count,
    array_agg(id ORDER BY id) AS rule_ids,
    array_agg(DISTINCT category ORDER BY category) AS categories
   FROM public.v_agent_rules_exploded
  WHERE (enforcement = 'halt'::text)
  GROUP BY agent_name, tenant_id
  ORDER BY agent_name;


--
-- Name: v_hud_factory_coverage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_hud_factory_coverage AS
 SELECT factory_tenant,
    count(DISTINCT lower(agent_name)) AS agents_tested,
    count(DISTINCT lower(agent_name)) FILTER (WHERE (pass = true)) AS agents_passed,
    count(DISTINCT lower(agent_name)) FILTER (WHERE (pass = false)) AS agents_failed,
    count(DISTINCT lower(agent_name)) FILTER (WHERE (pass IS NULL)) AS agents_unscored,
    max(run_date) AS last_eval
   FROM factory.rimmer_runs
  GROUP BY factory_tenant;


--
-- Name: v_hud_rewrite_queue; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_hud_rewrite_queue AS
 SELECT lower(agent_name) AS agent_name,
    score AS l1_score,
    notes AS rimmer_notes,
    run_date
   FROM factory.rimmer_runs
  WHERE ((layer = 1) AND ((pass = false) OR (pass IS NULL)) AND (factory_tenant = 'omatic'::text))
  ORDER BY score;


--
-- Name: v_mcp_readiness; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_mcp_readiness AS
 SELECT r.connector_id,
    r.display_name,
    r.criticality,
    r.category,
    r.agent_primary,
    r.platform_availability,
    r.fallback_behavior,
    COALESCE(s.probe_result, 'untested'::text) AS probe_result,
    COALESCE(s.fallback_active, false) AS fallback_active,
    s.probe_note,
    s.probed_at,
        CASE
            WHEN (COALESCE(s.probe_result, 'untested'::text) = 'connected'::text) THEN 'OK'::text
            WHEN (COALESCE(s.probe_result, 'untested'::text) = 'blocked'::text) THEN 'BLOCKED'::text
            WHEN ((r.criticality = 'critical'::text) AND (COALESCE(s.probe_result, 'untested'::text) <> 'connected'::text)) THEN 'CRITICAL-DOWN'::text
            WHEN ((r.criticality = 'standard'::text) AND (COALESCE(s.probe_result, 'untested'::text) <> 'connected'::text)) THEN 'DEGRADED'::text
            ELSE 'REDUCED'::text
        END AS status_label
   FROM (factory.mcp_registry r
     LEFT JOIN factory.session_mcp_status s ON (((s.tenant_id = r.tenant_id) AND (s.connector_id = r.connector_id) AND (s.session_id = ( SELECT max(fs.id) AS max
           FROM factory.factory_sessions fs
          WHERE (fs.tenant_id = r.tenant_id))))))
  WHERE ((r.active = true) AND (r.tenant_id = 'omatic'::text))
  ORDER BY
        CASE r.criticality
            WHEN 'critical'::text THEN 1
            WHEN 'standard'::text THEN 2
            ELSE 3
        END, r.connector_id;


--
-- Name: v_mcp_readiness_by_session; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_mcp_readiness_by_session AS
 SELECT s.session_id,
    fs.session_date,
    fs.platform AS session_platform,
    r.connector_id,
    r.display_name,
    r.criticality,
    r.category,
    r.agent_primary,
    r.platform_availability,
    r.fallback_behavior,
    COALESCE(s.probe_result, 'untested'::text) AS probe_result,
    COALESCE(s.fallback_active, false) AS fallback_active,
    s.probe_note,
    s.probed_at,
        CASE
            WHEN (COALESCE(s.probe_result, 'untested'::text) = 'connected'::text) THEN 'OK'::text
            WHEN (COALESCE(s.probe_result, 'untested'::text) = 'blocked'::text) THEN 'BLOCKED'::text
            WHEN ((r.criticality = 'critical'::text) AND (COALESCE(s.probe_result, 'untested'::text) <> 'connected'::text)) THEN 'CRITICAL-DOWN'::text
            WHEN ((r.criticality = 'standard'::text) AND (COALESCE(s.probe_result, 'untested'::text) <> 'connected'::text)) THEN 'DEGRADED'::text
            ELSE 'REDUCED'::text
        END AS status_label
   FROM ((factory.session_mcp_status s
     JOIN factory.mcp_registry r ON ((r.connector_id = s.connector_id)))
     LEFT JOIN factory.factory_sessions fs ON ((fs.id = s.session_id)))
  WHERE (r.active = true);


--
-- Name: v_open_site_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_open_site_tasks AS
 SELECT id,
    priority,
    owner,
    ref_id,
    title,
    description
   FROM factory.tasks t
  WHERE (((status)::text = 'open'::text) AND ((category)::text = 'SITE'::text))
  ORDER BY priority, ref_id, id;


--
-- Name: v_open_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_open_tasks AS
 SELECT t.id,
    t.priority,
    t.category,
    t.owner,
    t.title,
    t.description,
    t.ref_id,
    t.blocked_by,
    b.title AS blocked_by_title,
    (t.created_at)::date AS added
   FROM (factory.tasks t
     LEFT JOIN factory.tasks b ON ((t.blocked_by = b.id)))
  WHERE ((t.status)::text = 'open'::text)
  ORDER BY t.priority, t.category, t.id;


--
-- Name: v_recent_sessions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_recent_sessions AS
 SELECT session_date,
    platform,
    session_type,
    summary,
    resume_notes,
    agents_active
   FROM factory.factory_sessions
  ORDER BY session_date DESC
 LIMIT 5;


--
-- Name: v_research_active; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_research_active AS
 SELECT id,
    topic,
    "left"(summary, 200) AS summary_preview,
    tags,
    collected_by,
    session_id,
    (created_at)::date AS collected_date
   FROM brain.research
  WHERE (status = 'active'::text)
  ORDER BY created_at DESC;


--
-- Name: v_retrieval_eval_case_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_retrieval_eval_case_summary AS
 SELECT c.tenant_id,
    c.case_id,
    c.query_text,
    c.target_function,
    c.active,
    c.expected_sources,
    latest.run_id AS latest_run_id,
    latest.expected_found AS latest_expected_found,
    latest.first_match_rank AS latest_first_match_rank,
    latest.created_at AS latest_result_at
   FROM (factory.retrieval_eval_cases c
     LEFT JOIN LATERAL ( SELECT r.run_id,
            r.expected_found,
            r.first_match_rank,
            r.created_at
           FROM (factory.retrieval_eval_results r
             JOIN factory.retrieval_eval_runs run ON ((run.run_id = r.run_id)))
          WHERE ((r.case_id = c.case_id) AND (run.tenant_id = c.tenant_id))
          ORDER BY r.created_at DESC
         LIMIT 1) latest ON (true));


--
-- Name: v_retrieval_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_retrieval_health AS
 SELECT tenant_id,
    count(*) AS event_count,
    count(*) FILTER (WHERE used_vector) AS vector_event_count,
    count(*) FILTER (WHERE (NOT used_vector)) AS fts_only_event_count,
    round(avg(latency_ms) FILTER (WHERE (latency_ms IS NOT NULL)), 2) AS avg_latency_ms,
    max(created_at) AS last_event_at
   FROM factory.retrieval_events e
  GROUP BY tenant_id;


--
-- Name: v_rimmer_agent_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_agent_summary AS
 SELECT DISTINCT ON (agent_name) agent_name,
    model_tested,
    layer,
    score,
    pass,
    (run_date)::date AS last_run
   FROM factory.rimmer_runs
  ORDER BY agent_name, run_date DESC;


--
-- Name: v_rimmer_compliance_trend; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_compliance_trend AS
 SELECT agent_name,
    factory_id,
    layer,
    (run_date)::date AS run_date,
    score,
    pass,
    model_tested,
    agent_version,
    agent_sig
   FROM ( SELECT rimmer_runs.id,
            rimmer_runs.run_date,
            rimmer_runs.model_tested,
            rimmer_runs.agent_name,
            rimmer_runs.layer,
            rimmer_runs.score,
            rimmer_runs.pass,
            rimmer_runs.criteria_results,
            rimmer_runs.session_id,
            rimmer_runs.run_by,
            rimmer_runs.notes,
            rimmer_runs.created_at,
            rimmer_runs.factory_id,
            rimmer_runs.factory_tenant,
            rimmer_runs.run_mode,
            rimmer_runs.test_suite_version,
            rimmer_runs.agent_version,
            rimmer_runs.agent_sig,
            row_number() OVER (PARTITION BY rimmer_runs.agent_name, rimmer_runs.factory_id ORDER BY rimmer_runs.run_date DESC) AS rn
           FROM factory.rimmer_runs) ranked
  WHERE (rn <= 10)
  ORDER BY agent_name, factory_id, ((run_date)::date) DESC;


--
-- Name: v_rimmer_latest; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_latest AS
 SELECT DISTINCT ON (agent_name, factory_id) agent_name,
    factory_id,
    factory_tenant,
    model_tested,
    layer,
    score,
    pass,
    run_mode,
    agent_version,
    agent_sig,
    (run_date)::date AS last_run
   FROM factory.rimmer_runs
  ORDER BY agent_name, factory_id, run_date DESC;


--
-- Name: v_rimmer_cross_factory; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_cross_factory AS
 SELECT factory_id,
    factory_tenant,
    count(DISTINCT agent_name) AS agents_tested,
    round(avg(score), 2) AS avg_score,
    sum(
        CASE
            WHEN pass THEN 1
            ELSE 0
        END) AS passed,
    sum(
        CASE
            WHEN (NOT pass) THEN 1
            ELSE 0
        END) AS failed,
    max(last_run) AS last_run
   FROM public.v_rimmer_latest
  GROUP BY factory_id, factory_tenant
  ORDER BY factory_id;


--
-- Name: v_rimmer_drift; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_drift AS
 SELECT agent_name,
    factory_id,
    score AS current_score,
    lag(score) OVER (PARTITION BY agent_name, factory_id ORDER BY rimmer_runs.run_date) AS previous_score,
    (score - lag(score) OVER (PARTITION BY agent_name, factory_id ORDER BY rimmer_runs.run_date)) AS delta,
    (run_date)::date AS run_date
   FROM factory.rimmer_runs
  ORDER BY agent_name, factory_id, ((run_date)::date) DESC;


--
-- Name: v_rimmer_fails_active; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_fails_active AS
 SELECT lower(agent_name) AS agent_name,
    factory_tenant,
    layer,
    score,
    notes,
    (run_date)::date AS run_date
   FROM factory.rimmer_runs
  WHERE ((pass = false) AND (NOT (EXISTS ( SELECT 1
           FROM factory.rimmer_runs r2
          WHERE ((lower(r2.agent_name) = lower(rimmer_runs.agent_name)) AND (r2.factory_tenant = rimmer_runs.factory_tenant) AND (r2.layer = rimmer_runs.layer) AND (r2.pass = true) AND (r2.run_date > rimmer_runs.run_date))))))
  ORDER BY factory_tenant, layer, score;


--
-- Name: v_rimmer_history; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_history AS
 SELECT id,
    (run_date)::date AS run_date,
    agent_name,
    model_tested,
    layer,
    score,
    pass,
    notes
   FROM factory.rimmer_runs
  ORDER BY ((run_date)::date) DESC, agent_name;


--
-- Name: v_rimmer_l1_improvement; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_l1_improvement AS
 SELECT lower(agent_name) AS agent_name,
    factory_tenant,
    count(*) AS total_l1_runs,
    min(score) AS first_score,
    max(score) AS best_score,
    round((max(score) - min(score)), 2) AS score_delta,
    bool_or(pass) AS ever_passed,
    (max(run_date))::date AS last_run
   FROM factory.rimmer_runs
  WHERE ((layer = 1) AND (score IS NOT NULL) AND (score <= (5)::numeric))
  GROUP BY (lower(agent_name)), factory_tenant
 HAVING (count(*) > 1)
  ORDER BY (round((max(score) - min(score)), 2)) DESC;


--
-- Name: v_rimmer_omatic_canonical; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_omatic_canonical AS
 WITH l1 AS (
         SELECT DISTINCT ON ((lower(rimmer_runs.agent_name))) lower(rimmer_runs.agent_name) AS agent_name,
            rimmer_runs.score AS l1_score,
            rimmer_runs.pass AS l1_pass,
            rimmer_runs.notes AS l1_notes,
            rimmer_runs.agent_version AS l1_agent_version,
            rimmer_runs.run_date AS l1_run_date
           FROM factory.rimmer_runs
          WHERE ((rimmer_runs.factory_tenant = 'omatic'::text) AND (rimmer_runs.layer = 1))
          ORDER BY (lower(rimmer_runs.agent_name)), rimmer_runs.run_date DESC
        ), l2 AS (
         SELECT DISTINCT ON ((lower(rimmer_runs.agent_name))) lower(rimmer_runs.agent_name) AS agent_name,
            rimmer_runs.score AS l2_score,
            rimmer_runs.pass AS l2_pass,
            rimmer_runs.notes AS l2_notes,
            rimmer_runs.run_date AS l2_run_date
           FROM factory.rimmer_runs
          WHERE ((rimmer_runs.factory_tenant = 'omatic'::text) AND (rimmer_runs.layer = 2) AND (rimmer_runs.pass IS NOT FALSE))
          ORDER BY (lower(rimmer_runs.agent_name)), rimmer_runs.run_date DESC
        )
 SELECT COALESCE(l1.agent_name, l2.agent_name) AS agent_name,
    l1.l1_score,
    l1.l1_pass,
    l1.l1_agent_version,
    (l1.l1_run_date)::date AS l1_run_date,
    l2.l2_score,
    l2.l2_pass,
    (l2.l2_run_date)::date AS l2_run_date,
        CASE
            WHEN ((l1.l1_pass = true) AND (l2.l2_pass = true)) THEN 'PRODUCTION_READY'::text
            WHEN ((l1.l1_pass = true) AND ((l2.l2_pass IS NULL) OR (l2.l2_pass = false))) THEN 'L1_PASS_AWAITING_L2'::text
            WHEN (l1.l1_pass = false) THEN 'REWRITE_REQUIRED'::text
            WHEN (l1.l1_pass IS NULL) THEN 'NOT_EVALUATED'::text
            ELSE 'DEFERRED'::text
        END AS readiness_tier
   FROM (l1
     FULL JOIN l2 ON ((l1.agent_name = l2.agent_name)))
  ORDER BY
        CASE
            WHEN ((l1.l1_pass = true) AND (l2.l2_pass = true)) THEN 'PRODUCTION_READY'::text
            WHEN ((l1.l1_pass = true) AND ((l2.l2_pass IS NULL) OR (l2.l2_pass = false))) THEN 'L1_PASS_AWAITING_L2'::text
            WHEN (l1.l1_pass = false) THEN 'REWRITE_REQUIRED'::text
            WHEN (l1.l1_pass IS NULL) THEN 'NOT_EVALUATED'::text
            ELSE 'DEFERRED'::text
        END, l1.l1_score DESC NULLS LAST;


--
-- Name: v_rimmer_satellite_coverage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_rimmer_satellite_coverage AS
 SELECT factory_tenant,
    count(DISTINCT lower(agent_name)) AS agents_with_l2,
    count(*) AS total_l2_runs,
    count(*) FILTER (WHERE (pass = true)) AS l2_passes,
    count(*) FILTER (WHERE (pass IS NULL)) AS unscored,
    count(*) FILTER (WHERE ((criteria_results ->> 'correction_evidence_found'::text) = 'true'::text)) AS correction_evidence_found,
    count(*) FILTER (WHERE (((criteria_results ->> 'insufficient_evidence'::text) = 'true'::text) OR ((criteria_results -> 'evidence_samples'::text) = '0'::jsonb))) AS insufficient_evidence,
    (max(run_date))::date AS last_collection
   FROM factory.rimmer_runs
  WHERE (layer = 2)
  GROUP BY factory_tenant
  ORDER BY factory_tenant;


--
-- Name: v_sop_registry; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sop_registry AS
 SELECT sop_id,
    title,
    version,
    owner,
    trigger_condition,
    trigger_phrases,
    summary,
    status,
    file_path,
    updated_at
   FROM factory.sop_registry
  WHERE (status = 'active'::text)
  ORDER BY sop_id;


--
-- Name: v_startup_rules; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_startup_rules AS
 SELECT kr.id,
    kr.enforcement,
    kr.rule,
    kr.category,
    kr.rule_type,
    lower(TRIM(BOTH FROM agent.agent_name)) AS agent,
    kr.applies_to,
    kr.tenant_id,
    kr.updated_at
   FROM (factory.known_rules kr
     CROSS JOIN LATERAL regexp_split_to_table(regexp_replace(COALESCE(kr.applies_to, ''::text), '[{}\[\]"]'::text, ''::text, 'g'::text), '\s*,\s*'::text) agent(agent_name))
  WHERE (((kr.category)::text = 'startup'::text) AND (TRIM(BOTH FROM agent.agent_name) <> ''::text));


--
-- Name: v_tasks_by_owner; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_tasks_by_owner AS
 SELECT owner,
    count(*) AS open_tasks,
    sum(
        CASE
            WHEN (priority = 1) THEN 1
            ELSE 0
        END) AS critical,
    sum(
        CASE
            WHEN (priority = 2) THEN 1
            ELSE 0
        END) AS high,
    sum(
        CASE
            WHEN (priority = 3) THEN 1
            ELSE 0
        END) AS normal,
    sum(
        CASE
            WHEN (priority = 4) THEN 1
            ELSE 0
        END) AS low,
    string_agg(DISTINCT (category)::text, ', '::text) AS categories
   FROM factory.tasks
  WHERE ((status)::text = 'open'::text)
  GROUP BY owner
  ORDER BY (count(*)) DESC;


--
-- Name: v_tier1_coverage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_tier1_coverage AS
 WITH expected AS (
         SELECT 'tasks'::text AS source_table,
            ( SELECT count(*) AS count
                   FROM factory.tasks
                  WHERE (tasks.tenant_id = 'omatic'::text)) AS source_rows
        UNION ALL
         SELECT 'decisions'::text,
            ( SELECT count(*) AS count
                   FROM factory.decisions
                  WHERE (decisions.tenant_id = 'omatic'::text)) AS count
        UNION ALL
         SELECT 'brand_messaging'::text,
            ( SELECT count(*) AS count
                   FROM brand.brand_messaging
                  WHERE (brand_messaging.tenant_id = 'omatic'::text)) AS count
        UNION ALL
         SELECT 'project_knowledge'::text,
            ( SELECT count(*) AS count
                   FROM brain.project_knowledge
                  WHERE ((project_knowledge.tenant_id = 'omatic'::text) AND COALESCE(project_knowledge.is_active, true))) AS count
        UNION ALL
         SELECT 'known_rules'::text,
            ( SELECT count(*) AS count
                   FROM factory.known_rules
                  WHERE (known_rules.tenant_id = 'omatic'::text)) AS count
        UNION ALL
         SELECT 'sop_registry'::text,
            ( SELECT count(*) AS count
                   FROM factory.sop_registry
                  WHERE (sop_registry.tenant_id = 'omatic'::text)) AS count
        UNION ALL
         SELECT 'agent_identity'::text,
            ( SELECT count(*) AS count
                   FROM factory.agent_identity
                  WHERE (agent_identity.tenant_id = 'omatic'::text)) AS count
        UNION ALL
         SELECT 'mcp_registry'::text,
            ( SELECT count(*) AS count
                   FROM factory.mcp_registry
                  WHERE (mcp_registry.tenant_id = 'omatic'::text)) AS count
        ), indexed AS (
         SELECT semantic_index.source_table,
            count(*) AS tier1_rows,
            count(*) FILTER (WHERE ((semantic_index.embedding IS NULL) OR semantic_index.embedding_stale)) AS pending_embed
           FROM brain.semantic_index
          WHERE (semantic_index.tenant_id = 'omatic'::text)
          GROUP BY semantic_index.source_table
        )
 SELECT e.source_table,
    e.source_rows,
    COALESCE(i.tier1_rows, (0)::bigint) AS tier1_rows,
    COALESCE(i.pending_embed, (0)::bigint) AS pending_embed,
        CASE
            WHEN ((COALESCE(i.tier1_rows, (0)::bigint) = 0) AND (e.source_rows > 0)) THEN 'MISSING'::text
            WHEN (COALESCE(i.tier1_rows, (0)::bigint) < e.source_rows) THEN 'PARTIAL'::text
            ELSE 'OK'::text
        END AS coverage_status
   FROM (expected e
     LEFT JOIN indexed i USING (source_table))
  ORDER BY
        CASE
            WHEN ((COALESCE(i.tier1_rows, (0)::bigint) = 0) AND (e.source_rows > 0)) THEN 0
            WHEN (COALESCE(i.tier1_rows, (0)::bigint) < e.source_rows) THEN 1
            ELSE 2
        END, e.source_table;


--
-- Name: work_claims; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.work_claims AS
 SELECT id,
    tenant_id,
    resource_type,
    resource_id,
    claimed_by,
    session_id,
    claimed_at,
    expires_at,
    released_at,
    released_by,
    status,
    factory_id,
    platform,
    claim_note
   FROM factory.work_claims;


--
-- Name: agent_memory id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.agent_memory ALTER COLUMN id SET DEFAULT nextval('brain.agent_memory_id_seq'::regclass);


--
-- Name: docling_registry id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.docling_registry ALTER COLUMN id SET DEFAULT nextval('brain.docling_registry_id_seq'::regclass);


--
-- Name: document_chunks id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.document_chunks ALTER COLUMN id SET DEFAULT nextval('brain.document_chunks_id_seq'::regclass);


--
-- Name: project_knowledge id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.project_knowledge ALTER COLUMN id SET DEFAULT nextval('brain.project_knowledge_id_seq'::regclass);


--
-- Name: research id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.research ALTER COLUMN id SET DEFAULT nextval('brain.research_id_seq'::regclass);


--
-- Name: semantic_index id; Type: DEFAULT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.semantic_index ALTER COLUMN id SET DEFAULT nextval('brain.semantic_index_id_seq'::regclass);


--
-- Name: brand_assets id; Type: DEFAULT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.brand_assets ALTER COLUMN id SET DEFAULT nextval('brand.brand_assets_id_seq'::regclass);


--
-- Name: brand_messaging id; Type: DEFAULT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.brand_messaging ALTER COLUMN id SET DEFAULT nextval('brand.brand_messaging_id_seq'::regclass);


--
-- Name: content_staging id; Type: DEFAULT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.content_staging ALTER COLUMN id SET DEFAULT nextval('brand.content_staging_id_seq'::regclass);


--
-- Name: decisions id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.decisions ALTER COLUMN id SET DEFAULT nextval('factory.decisions_id_seq'::regclass);


--
-- Name: factory_agreements id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_agreements ALTER COLUMN id SET DEFAULT nextval('factory.factory_agreements_id_seq'::regclass);


--
-- Name: factory_sessions id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_sessions ALTER COLUMN id SET DEFAULT nextval('factory.factory_sessions_id_seq'::regclass);


--
-- Name: known_rules id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.known_rules ALTER COLUMN id SET DEFAULT nextval('factory.known_rules_id_seq'::regclass);


--
-- Name: mcp_registry id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.mcp_registry ALTER COLUMN id SET DEFAULT nextval('factory.mcp_registry_id_seq'::regclass);


--
-- Name: persona_archetype id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_archetype ALTER COLUMN id SET DEFAULT nextval('factory.persona_archetype_id_seq'::regclass);


--
-- Name: persona_asset id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_asset ALTER COLUMN id SET DEFAULT nextval('factory.persona_asset_id_seq'::regclass);


--
-- Name: persona_build id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_build ALTER COLUMN id SET DEFAULT nextval('factory.persona_build_id_seq'::regclass);


--
-- Name: persona_character_bible id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_bible ALTER COLUMN id SET DEFAULT nextval('factory.persona_character_bible_id_seq'::regclass);


--
-- Name: persona_character_dimension id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_dimension ALTER COLUMN id SET DEFAULT nextval('factory.persona_character_dimension_id_seq'::regclass);


--
-- Name: persona_drift_check id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_drift_check ALTER COLUMN id SET DEFAULT nextval('factory.persona_drift_check_id_seq'::regclass);


--
-- Name: persona_eval_criteria id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_eval_criteria ALTER COLUMN id SET DEFAULT nextval('factory.persona_eval_criteria_id_seq'::regclass);


--
-- Name: persona_export_target id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_export_target ALTER COLUMN id SET DEFAULT nextval('factory.persona_export_target_id_seq'::regclass);


--
-- Name: persona_lane_contract id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_lane_contract ALTER COLUMN id SET DEFAULT nextval('factory.persona_lane_contract_id_seq'::regclass);


--
-- Name: persona_provenance id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_provenance ALTER COLUMN id SET DEFAULT nextval('factory.persona_provenance_id_seq'::regclass);


--
-- Name: persona_strength id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_strength ALTER COLUMN id SET DEFAULT nextval('factory.persona_strength_id_seq'::regclass);


--
-- Name: persona_tool id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_tool ALTER COLUMN id SET DEFAULT nextval('factory.persona_tool_id_seq'::regclass);


--
-- Name: persona_version id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_version ALTER COLUMN id SET DEFAULT nextval('factory.persona_version_id_seq'::regclass);


--
-- Name: persona_voice_contract id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_voice_contract ALTER COLUMN id SET DEFAULT nextval('factory.persona_voice_contract_id_seq'::regclass);


--
-- Name: process_changelog id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.process_changelog ALTER COLUMN id SET DEFAULT nextval('factory.process_changelog_id_seq'::regclass);


--
-- Name: retrieval_eval_results result_id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_results ALTER COLUMN result_id SET DEFAULT nextval('factory.retrieval_eval_results_result_id_seq'::regclass);


--
-- Name: retrieval_eval_runs run_id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_runs ALTER COLUMN run_id SET DEFAULT nextval('factory.retrieval_eval_runs_run_id_seq'::regclass);


--
-- Name: retrieval_events id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_events ALTER COLUMN id SET DEFAULT nextval('factory.retrieval_events_id_seq'::regclass);


--
-- Name: rimmer_runs id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.rimmer_runs ALTER COLUMN id SET DEFAULT nextval('factory.rimmer_runs_id_seq'::regclass);


--
-- Name: rimmer_test_suite id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.rimmer_test_suite ALTER COLUMN id SET DEFAULT nextval('factory.rimmer_test_suite_id_seq'::regclass);


--
-- Name: session_log id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_log ALTER COLUMN id SET DEFAULT nextval('factory.session_log_id_seq'::regclass);


--
-- Name: session_mcp_status id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_mcp_status ALTER COLUMN id SET DEFAULT nextval('factory.session_mcp_status_id_seq'::regclass);


--
-- Name: sig_log id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sig_log ALTER COLUMN id SET DEFAULT nextval('factory.sig_log_id_seq'::regclass);


--
-- Name: sop_steps id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sop_steps ALTER COLUMN id SET DEFAULT nextval('factory.sop_steps_id_seq'::regclass);


--
-- Name: tasks id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.tasks ALTER COLUMN id SET DEFAULT nextval('factory.tasks_id_seq'::regclass);


--
-- Name: work_claims id; Type: DEFAULT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.work_claims ALTER COLUMN id SET DEFAULT nextval('factory.work_claims_id_seq'::regclass);


--
-- Name: agent_memory agent_memory_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.agent_memory
    ADD CONSTRAINT agent_memory_pkey PRIMARY KEY (id);


--
-- Name: docling_registry docling_registry_file_path_key; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.docling_registry
    ADD CONSTRAINT docling_registry_file_path_key UNIQUE (file_path);


--
-- Name: docling_registry docling_registry_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.docling_registry
    ADD CONSTRAINT docling_registry_pkey PRIMARY KEY (id);


--
-- Name: document_chunks document_chunks_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.document_chunks
    ADD CONSTRAINT document_chunks_pkey PRIMARY KEY (id);


--
-- Name: document_chunks document_chunks_tenant_source_chunk_key; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.document_chunks
    ADD CONSTRAINT document_chunks_tenant_source_chunk_key UNIQUE (tenant_id, source_type, source_name, chunk_index);


--
-- Name: project_knowledge project_knowledge_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.project_knowledge
    ADD CONSTRAINT project_knowledge_pkey PRIMARY KEY (id);


--
-- Name: research research_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.research
    ADD CONSTRAINT research_pkey PRIMARY KEY (id);


--
-- Name: semantic_index semantic_index_pkey; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.semantic_index
    ADD CONSTRAINT semantic_index_pkey PRIMARY KEY (id);


--
-- Name: semantic_index semantic_index_tenant_id_source_table_source_id_key; Type: CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.semantic_index
    ADD CONSTRAINT semantic_index_tenant_id_source_table_source_id_key UNIQUE (tenant_id, source_table, source_id);


--
-- Name: brand_assets brand_assets_pkey; Type: CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.brand_assets
    ADD CONSTRAINT brand_assets_pkey PRIMARY KEY (id);


--
-- Name: brand_assets brand_assets_rel_path_key; Type: CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.brand_assets
    ADD CONSTRAINT brand_assets_rel_path_key UNIQUE (rel_path);


--
-- Name: brand_messaging brand_messaging_pkey; Type: CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.brand_messaging
    ADD CONSTRAINT brand_messaging_pkey PRIMARY KEY (id);


--
-- Name: content_staging content_staging_pkey; Type: CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.content_staging
    ADD CONSTRAINT content_staging_pkey PRIMARY KEY (id);


--
-- Name: agent_identity agent_identity_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.agent_identity
    ADD CONSTRAINT agent_identity_pkey PRIMARY KEY (agent_name);


--
-- Name: agent_state agent_state_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.agent_state
    ADD CONSTRAINT agent_state_pkey PRIMARY KEY (agent_name);


--
-- Name: decisions decisions_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.decisions
    ADD CONSTRAINT decisions_pkey PRIMARY KEY (id);


--
-- Name: decommissioned_term_allowlist decommissioned_term_allowlist_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.decommissioned_term_allowlist
    ADD CONSTRAINT decommissioned_term_allowlist_pkey PRIMARY KEY (tenant_id, source_table, source_id, term);


--
-- Name: decommissioned_terms decommissioned_terms_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.decommissioned_terms
    ADD CONSTRAINT decommissioned_terms_pkey PRIMARY KEY (term);


--
-- Name: factory_agreements factory_agreements_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_agreements
    ADD CONSTRAINT factory_agreements_pkey PRIMARY KEY (id);


--
-- Name: factory_agreements factory_agreements_tenant_id_agent_name_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_agreements
    ADD CONSTRAINT factory_agreements_tenant_id_agent_name_key UNIQUE (tenant_id, agent_name);


--
-- Name: factory_config factory_config_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_config
    ADD CONSTRAINT factory_config_pkey PRIMARY KEY (key, tenant_id);


--
-- Name: factory_lanes factory_lanes_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_lanes
    ADD CONSTRAINT factory_lanes_pkey PRIMARY KEY (tenant_id, lane);


--
-- Name: factory_sessions factory_sessions_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.factory_sessions
    ADD CONSTRAINT factory_sessions_pkey PRIMARY KEY (id);


--
-- Name: known_rules known_rules_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.known_rules
    ADD CONSTRAINT known_rules_pkey PRIMARY KEY (id);


--
-- Name: mcp_registry mcp_registry_connector_id_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.mcp_registry
    ADD CONSTRAINT mcp_registry_connector_id_key UNIQUE (connector_id);


--
-- Name: mcp_registry mcp_registry_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.mcp_registry
    ADD CONSTRAINT mcp_registry_pkey PRIMARY KEY (id);


--
-- Name: persona_archetype persona_archetype_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_archetype
    ADD CONSTRAINT persona_archetype_pkey PRIMARY KEY (id);


--
-- Name: persona_archetype persona_archetype_version_id_layer_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_archetype
    ADD CONSTRAINT persona_archetype_version_id_layer_key UNIQUE (version_id, layer);


--
-- Name: persona_asset persona_asset_agent_name_asset_type_variant_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_asset
    ADD CONSTRAINT persona_asset_agent_name_asset_type_variant_key UNIQUE (agent_name, asset_type, variant);


--
-- Name: persona_asset persona_asset_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_asset
    ADD CONSTRAINT persona_asset_pkey PRIMARY KEY (id);


--
-- Name: persona_build persona_build_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_build
    ADD CONSTRAINT persona_build_pkey PRIMARY KEY (id);


--
-- Name: persona_character_bible persona_character_bible_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_bible
    ADD CONSTRAINT persona_character_bible_pkey PRIMARY KEY (id);


--
-- Name: persona_character_dimension persona_character_dimension_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_dimension
    ADD CONSTRAINT persona_character_dimension_pkey PRIMARY KEY (id);


--
-- Name: persona_character_dimension persona_character_dimension_version_id_dimension_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_dimension
    ADD CONSTRAINT persona_character_dimension_version_id_dimension_key UNIQUE (version_id, dimension);


--
-- Name: persona_drift_check persona_drift_check_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_drift_check
    ADD CONSTRAINT persona_drift_check_pkey PRIMARY KEY (id);


--
-- Name: persona_eval_criteria persona_eval_criteria_agent_name_criterion_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_eval_criteria
    ADD CONSTRAINT persona_eval_criteria_agent_name_criterion_key UNIQUE (agent_name, criterion);


--
-- Name: persona_eval_criteria persona_eval_criteria_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_eval_criteria
    ADD CONSTRAINT persona_eval_criteria_pkey PRIMARY KEY (id);


--
-- Name: persona_export_target persona_export_target_agent_name_target_type_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_export_target
    ADD CONSTRAINT persona_export_target_agent_name_target_type_key UNIQUE (agent_name, target_type);


--
-- Name: persona_export_target persona_export_target_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_export_target
    ADD CONSTRAINT persona_export_target_pkey PRIMARY KEY (id);


--
-- Name: persona_lane_contract persona_lane_contract_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_lane_contract
    ADD CONSTRAINT persona_lane_contract_pkey PRIMARY KEY (id);


--
-- Name: persona persona_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona
    ADD CONSTRAINT persona_pkey PRIMARY KEY (agent_name);


--
-- Name: persona_provenance persona_provenance_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_provenance
    ADD CONSTRAINT persona_provenance_pkey PRIMARY KEY (id);


--
-- Name: persona_strength persona_strength_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_strength
    ADD CONSTRAINT persona_strength_pkey PRIMARY KEY (id);


--
-- Name: persona_strength persona_strength_version_id_strength_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_strength
    ADD CONSTRAINT persona_strength_version_id_strength_key UNIQUE (version_id, strength);


--
-- Name: persona_tool persona_tool_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_tool
    ADD CONSTRAINT persona_tool_pkey PRIMARY KEY (id);


--
-- Name: persona_tool persona_tool_version_id_tool_name_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_tool
    ADD CONSTRAINT persona_tool_version_id_tool_name_key UNIQUE (version_id, tool_name);


--
-- Name: persona_version persona_version_agent_name_version_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_version
    ADD CONSTRAINT persona_version_agent_name_version_key UNIQUE (agent_name, version);


--
-- Name: persona_version persona_version_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_version
    ADD CONSTRAINT persona_version_pkey PRIMARY KEY (id);


--
-- Name: persona_voice_contract persona_voice_contract_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_voice_contract
    ADD CONSTRAINT persona_voice_contract_pkey PRIMARY KEY (id);


--
-- Name: process_changelog process_changelog_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.process_changelog
    ADD CONSTRAINT process_changelog_pkey PRIMARY KEY (id);


--
-- Name: retrieval_eval_cases retrieval_eval_cases_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_cases
    ADD CONSTRAINT retrieval_eval_cases_pkey PRIMARY KEY (case_id);


--
-- Name: retrieval_eval_results retrieval_eval_results_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_results
    ADD CONSTRAINT retrieval_eval_results_pkey PRIMARY KEY (result_id);


--
-- Name: retrieval_eval_runs retrieval_eval_runs_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_runs
    ADD CONSTRAINT retrieval_eval_runs_pkey PRIMARY KEY (run_id);


--
-- Name: retrieval_events retrieval_events_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_events
    ADD CONSTRAINT retrieval_events_pkey PRIMARY KEY (id);


--
-- Name: rimmer_runs rimmer_runs_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.rimmer_runs
    ADD CONSTRAINT rimmer_runs_pkey PRIMARY KEY (id);


--
-- Name: rimmer_test_suite rimmer_test_suite_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.rimmer_test_suite
    ADD CONSTRAINT rimmer_test_suite_pkey PRIMARY KEY (id);


--
-- Name: session_log session_log_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_log
    ADD CONSTRAINT session_log_pkey PRIMARY KEY (id);


--
-- Name: session_mcp_status session_mcp_status_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_mcp_status
    ADD CONSTRAINT session_mcp_status_pkey PRIMARY KEY (id);


--
-- Name: session_mcp_status session_mcp_status_session_id_connector_id_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_mcp_status
    ADD CONSTRAINT session_mcp_status_session_id_connector_id_key UNIQUE (session_id, connector_id);


--
-- Name: sig_log sig_log_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sig_log
    ADD CONSTRAINT sig_log_pkey PRIMARY KEY (id);


--
-- Name: sop_registry sop_registry_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sop_registry
    ADD CONSTRAINT sop_registry_pkey PRIMARY KEY (sop_id);


--
-- Name: sop_steps sop_steps_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sop_steps
    ADD CONSTRAINT sop_steps_pkey PRIMARY KEY (id);


--
-- Name: sop_steps sop_steps_sop_id_step_number_key; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sop_steps
    ADD CONSTRAINT sop_steps_sop_id_step_number_key UNIQUE (sop_id, step_number);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: work_claims work_claims_pkey; Type: CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.work_claims
    ADD CONSTRAINT work_claims_pkey PRIMARY KEY (id);


--
-- Name: document_chunks_embedding_hnsw; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX document_chunks_embedding_hnsw ON brain.document_chunks USING hnsw (embedding public.vector_cosine_ops) WHERE (embedding IS NOT NULL);


--
-- Name: document_chunks_embedding_hnsw_omatic; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX document_chunks_embedding_hnsw_omatic ON brain.document_chunks USING hnsw (embedding public.vector_cosine_ops) WHERE ((tenant_id = 'omatic'::text) AND (embedding IS NOT NULL));


--
-- Name: document_chunks_stale; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX document_chunks_stale ON brain.document_chunks USING btree (tenant_id) WHERE (embedding_stale = true);


--
-- Name: document_chunks_tsv_gin; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX document_chunks_tsv_gin ON brain.document_chunks USING gin (tsv);


--
-- Name: idx_agent_memory_type; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_agent_memory_type ON brain.agent_memory USING btree (agent_name, memory_type);


--
-- Name: idx_doc_chunks_source; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_doc_chunks_source ON brain.document_chunks USING btree (source_id, source_type);


--
-- Name: idx_doc_chunks_tenant; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_doc_chunks_tenant ON brain.document_chunks USING btree (tenant_id);


--
-- Name: idx_docling_category; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_docling_category ON brain.docling_registry USING btree (category);


--
-- Name: idx_docling_required; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_docling_required ON brain.docling_registry USING btree (docling_required);


--
-- Name: idx_document_chunks_staleness; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_document_chunks_staleness ON brain.document_chunks USING btree (embedded_at, created_at);


--
-- Name: idx_project_knowledge_active; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_project_knowledge_active ON brain.project_knowledge USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_project_knowledge_tenant; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_project_knowledge_tenant ON brain.project_knowledge USING btree (tenant_id);


--
-- Name: idx_project_knowledge_type; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_project_knowledge_type ON brain.project_knowledge USING btree (knowledge_type);


--
-- Name: idx_research_created; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_research_created ON brain.research USING btree (created_at DESC);


--
-- Name: idx_research_session; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_research_session ON brain.research USING btree (session_id);


--
-- Name: idx_research_status; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_research_status ON brain.research USING btree (status);


--
-- Name: idx_research_tags; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_research_tags ON brain.research USING gin (tags);


--
-- Name: idx_research_topic; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX idx_research_topic ON brain.research USING btree (topic);


--
-- Name: semantic_index_embedding_hnsw; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX semantic_index_embedding_hnsw ON brain.semantic_index USING hnsw (embedding public.vector_cosine_ops) WHERE (embedding IS NOT NULL);


--
-- Name: semantic_index_embedding_hnsw_omatic; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX semantic_index_embedding_hnsw_omatic ON brain.semantic_index USING hnsw (embedding public.vector_cosine_ops) WHERE ((tenant_id = 'omatic'::text) AND (embedding IS NOT NULL));


--
-- Name: semantic_index_stale; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX semantic_index_stale ON brain.semantic_index USING btree (tenant_id) WHERE (embedding_stale = true);


--
-- Name: semantic_index_tsv_gin; Type: INDEX; Schema: brain; Owner: -
--

CREATE INDEX semantic_index_tsv_gin ON brain.semantic_index USING gin (tsv);


--
-- Name: idx_brand_messaging_category; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_brand_messaging_category ON brand.brand_messaging USING btree (category);


--
-- Name: idx_brand_messaging_tenant; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_brand_messaging_tenant ON brand.brand_messaging USING btree (tenant_id);


--
-- Name: idx_staging_assigned; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_staging_assigned ON brand.content_staging USING btree (assigned_to);


--
-- Name: idx_staging_session; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_staging_session ON brand.content_staging USING btree (session_id);


--
-- Name: idx_staging_status; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_staging_status ON brand.content_staging USING btree (status);


--
-- Name: idx_staging_type; Type: INDEX; Schema: brand; Owner: -
--

CREATE INDEX idx_staging_type ON brand.content_staging USING btree (content_type);


--
-- Name: idx_agent_state_factory; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_agent_state_factory ON factory.agent_state USING btree (factory);


--
-- Name: idx_agent_state_status; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_agent_state_status ON factory.agent_state USING btree (status);


--
-- Name: idx_decisions_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_decisions_category ON factory.decisions USING btree (category);


--
-- Name: idx_decisions_date; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_decisions_date ON factory.decisions USING btree (decision_date);


--
-- Name: idx_factory_config_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_factory_config_category ON factory.factory_config USING btree (category, tenant_id);


--
-- Name: idx_factory_sessions_date; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_factory_sessions_date ON factory.factory_sessions USING btree (session_date);


--
-- Name: idx_factory_sessions_tenant; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_factory_sessions_tenant ON factory.factory_sessions USING btree (tenant_id);


--
-- Name: idx_known_rules_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_known_rules_category ON factory.known_rules USING btree (category);


--
-- Name: idx_known_rules_tenant_applies; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_known_rules_tenant_applies ON factory.known_rules USING btree (tenant_id, applies_to);


--
-- Name: idx_known_rules_tenant_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_known_rules_tenant_category ON factory.known_rules USING btree (tenant_id, category);


--
-- Name: idx_known_rules_tenant_type_enf; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_known_rules_tenant_type_enf ON factory.known_rules USING btree (tenant_id, rule_type, enforcement);


--
-- Name: idx_persona_archetype_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_archetype_ver ON factory.persona_archetype USING btree (version_id);


--
-- Name: idx_persona_asset_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_asset_agent ON factory.persona_asset USING btree (agent_name);


--
-- Name: idx_persona_bible_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_bible_ver ON factory.persona_character_bible USING btree (version_id);


--
-- Name: idx_persona_build_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_build_agent ON factory.persona_build USING btree (agent_name, target_type);


--
-- Name: idx_persona_dimension_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_dimension_ver ON factory.persona_character_dimension USING btree (version_id);


--
-- Name: idx_persona_drift_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_drift_agent ON factory.persona_drift_check USING btree (agent_name);


--
-- Name: idx_persona_eval_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_eval_agent ON factory.persona_eval_criteria USING btree (agent_name);


--
-- Name: idx_persona_export_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_export_agent ON factory.persona_export_target USING btree (agent_name);


--
-- Name: idx_persona_lane_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_lane_ver ON factory.persona_lane_contract USING btree (version_id);


--
-- Name: idx_persona_prov_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_prov_agent ON factory.persona_provenance USING btree (agent_name);


--
-- Name: idx_persona_strength_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_strength_ver ON factory.persona_strength USING btree (version_id);


--
-- Name: idx_persona_tool_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_tool_ver ON factory.persona_tool USING btree (version_id);


--
-- Name: idx_persona_version_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_version_agent ON factory.persona_version USING btree (agent_name);


--
-- Name: idx_persona_voice_ver; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_persona_voice_ver ON factory.persona_voice_contract USING btree (version_id);


--
-- Name: idx_retrieval_eval_cases_tenant_active; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_eval_cases_tenant_active ON factory.retrieval_eval_cases USING btree (tenant_id, active, target_function);


--
-- Name: idx_retrieval_eval_results_run_case; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_eval_results_run_case ON factory.retrieval_eval_results USING btree (run_id, case_id);


--
-- Name: idx_retrieval_eval_runs_tenant_started; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_eval_runs_tenant_started ON factory.retrieval_eval_runs USING btree (tenant_id, started_at DESC);


--
-- Name: idx_retrieval_events_function_created; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_events_function_created ON factory.retrieval_events USING btree (search_function, created_at DESC);


--
-- Name: idx_retrieval_events_tenant_created; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_events_tenant_created ON factory.retrieval_events USING btree (tenant_id, created_at DESC);


--
-- Name: idx_retrieval_events_used_vector; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_retrieval_events_used_vector ON factory.retrieval_events USING btree (used_vector, created_at DESC);


--
-- Name: idx_rimmer_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_rimmer_agent ON factory.rimmer_runs USING btree (agent_name);


--
-- Name: idx_rimmer_layer; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_rimmer_layer ON factory.rimmer_runs USING btree (layer);


--
-- Name: idx_rimmer_model; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_rimmer_model ON factory.rimmer_runs USING btree (model_tested);


--
-- Name: idx_rimmer_run_date; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_rimmer_run_date ON factory.rimmer_runs USING btree (run_date DESC);


--
-- Name: idx_session_log_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_session_log_agent ON factory.session_log USING btree (agent);


--
-- Name: idx_session_log_date; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_session_log_date ON factory.session_log USING btree (session_date);


--
-- Name: idx_session_log_tenant_event; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_session_log_tenant_event ON factory.session_log USING btree (tenant_id, event_type);


--
-- Name: idx_session_mcp_status_result; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_session_mcp_status_result ON factory.session_mcp_status USING btree (probe_result);


--
-- Name: idx_session_mcp_status_session; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_session_mcp_status_session ON factory.session_mcp_status USING btree (session_id);


--
-- Name: idx_sig_log_agent; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sig_log_agent ON factory.sig_log USING btree (agent_name);


--
-- Name: idx_sig_log_created; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sig_log_created ON factory.sig_log USING btree (created_at DESC);


--
-- Name: idx_sig_log_date; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sig_log_date ON factory.sig_log USING btree (log_date DESC);


--
-- Name: idx_sop_registry_status; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sop_registry_status ON factory.sop_registry USING btree (status);


--
-- Name: idx_sop_registry_tenant; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sop_registry_tenant ON factory.sop_registry USING btree (tenant_id);


--
-- Name: idx_sop_registry_tenant_status; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_sop_registry_tenant_status ON factory.sop_registry USING btree (tenant_id, status);


--
-- Name: idx_tasks_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_category ON factory.tasks USING btree (category);


--
-- Name: idx_tasks_created; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_created ON factory.tasks USING btree (created_at DESC);


--
-- Name: idx_tasks_owner; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_owner ON factory.tasks USING btree (owner);


--
-- Name: idx_tasks_priority; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_priority ON factory.tasks USING btree (priority);


--
-- Name: idx_tasks_status; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_status ON factory.tasks USING btree (status);


--
-- Name: idx_tasks_status_category; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_status_category ON factory.tasks USING btree (status, category);


--
-- Name: idx_tasks_tenant; Type: INDEX; Schema: factory; Owner: -
--

CREATE INDEX idx_tasks_tenant ON factory.tasks USING btree (tenant_id);


--
-- Name: mv_agent_eval_status_pk; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX mv_agent_eval_status_pk ON factory.mv_agent_eval_status USING btree (agent_name);


--
-- Name: mv_dashboard_pk; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX mv_dashboard_pk ON factory.mv_dashboard USING btree ((true));


--
-- Name: mv_embedding_health_pk; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX mv_embedding_health_pk ON factory.mv_embedding_health USING btree (tier, tenant_id);


--
-- Name: mv_factory_kernel_health_pk; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX mv_factory_kernel_health_pk ON factory.mv_factory_kernel_health USING btree (standard);


--
-- Name: mv_startup_snapshot_pk; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX mv_startup_snapshot_pk ON factory.mv_startup_snapshot USING btree (last_session_id);


--
-- Name: work_claims_active_uq; Type: INDEX; Schema: factory; Owner: -
--

CREATE UNIQUE INDEX work_claims_active_uq ON factory.work_claims USING btree (tenant_id, resource_type, resource_id) WHERE (status = 'active'::text);


--
-- Name: document_chunks trg_document_chunks_content_change; Type: TRIGGER; Schema: brain; Owner: -
--

CREATE TRIGGER trg_document_chunks_content_change BEFORE UPDATE ON brain.document_chunks FOR EACH ROW WHEN (((old.content IS DISTINCT FROM new.content) OR (old.source_type IS DISTINCT FROM new.source_type) OR (old.source_name IS DISTINCT FROM new.source_name) OR (old.source_id IS DISTINCT FROM new.source_id) OR (old.chunk_index IS DISTINCT FROM new.chunk_index))) EXECUTE FUNCTION public.fn_mark_document_chunk_stale();


--
-- Name: document_chunks trg_document_chunks_delete_cleanup; Type: TRIGGER; Schema: brain; Owner: -
--

CREATE TRIGGER trg_document_chunks_delete_cleanup AFTER DELETE ON brain.document_chunks FOR EACH ROW EXECUTE FUNCTION public.fn_document_chunk_delete_cleanup();


--
-- Name: project_knowledge trg_project_knowledge_content_change; Type: TRIGGER; Schema: brain; Owner: -
--

CREATE TRIGGER trg_project_knowledge_content_change AFTER UPDATE OF knowledge_type, title, detail ON brain.project_knowledge FOR EACH ROW WHEN (((old.knowledge_type IS DISTINCT FROM new.knowledge_type) OR (old.title IS DISTINCT FROM new.title) OR (old.detail IS DISTINCT FROM new.detail))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: project_knowledge trg_project_knowledge_delete_si; Type: TRIGGER; Schema: brain; Owner: -
--

CREATE TRIGGER trg_project_knowledge_delete_si AFTER DELETE ON brain.project_knowledge FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: project_knowledge trg_project_knowledge_seed_si; Type: TRIGGER; Schema: brain; Owner: -
--

CREATE TRIGGER trg_project_knowledge_seed_si AFTER INSERT ON brain.project_knowledge FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: brand_messaging trg_brand_messaging_content_change; Type: TRIGGER; Schema: brand; Owner: -
--

CREATE TRIGGER trg_brand_messaging_content_change AFTER UPDATE OF category, sub_type, content ON brand.brand_messaging FOR EACH ROW WHEN (((old.category IS DISTINCT FROM new.category) OR (old.sub_type IS DISTINCT FROM new.sub_type) OR (old.content IS DISTINCT FROM new.content))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: brand_messaging trg_brand_messaging_delete_si; Type: TRIGGER; Schema: brand; Owner: -
--

CREATE TRIGGER trg_brand_messaging_delete_si AFTER DELETE ON brand.brand_messaging FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: brand_messaging trg_brand_messaging_seed_si; Type: TRIGGER; Schema: brand; Owner: -
--

CREATE TRIGGER trg_brand_messaging_seed_si AFTER INSERT ON brand.brand_messaging FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: agent_identity trg_agent_identity_content_change; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_agent_identity_content_change AFTER UPDATE OF callsign, primary_domain, voice_anchor ON factory.agent_identity FOR EACH ROW WHEN ((((old.callsign)::text IS DISTINCT FROM (new.callsign)::text) OR (old.primary_domain IS DISTINCT FROM new.primary_domain) OR (old.voice_anchor IS DISTINCT FROM new.voice_anchor))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: agent_identity trg_agent_identity_delete_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_agent_identity_delete_si AFTER DELETE ON factory.agent_identity FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: agent_identity trg_agent_identity_seed_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_agent_identity_seed_si AFTER INSERT ON factory.agent_identity FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: decisions trg_decisions_content_change; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_decisions_content_change AFTER UPDATE OF title, decision, rationale ON factory.decisions FOR EACH ROW WHEN ((((old.title)::text IS DISTINCT FROM (new.title)::text) OR (old.decision IS DISTINCT FROM new.decision) OR (old.rationale IS DISTINCT FROM new.rationale))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: decisions trg_decisions_delete_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_decisions_delete_si AFTER DELETE ON factory.decisions FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: decisions trg_decisions_seed_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_decisions_seed_si AFTER INSERT ON factory.decisions FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: known_rules trg_known_rules_content_change; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_known_rules_content_change AFTER UPDATE OF rule, category ON factory.known_rules FOR EACH ROW WHEN (((old.rule IS DISTINCT FROM new.rule) OR ((old.category)::text IS DISTINCT FROM (new.category)::text))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: known_rules trg_known_rules_delete_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_known_rules_delete_si AFTER DELETE ON factory.known_rules FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: known_rules trg_known_rules_seed_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_known_rules_seed_si AFTER INSERT ON factory.known_rules FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: sop_registry trg_sop_registry_content_change; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_sop_registry_content_change AFTER UPDATE OF title, summary, full_body, sop_id ON factory.sop_registry FOR EACH ROW WHEN (((old.title IS DISTINCT FROM new.title) OR (old.summary IS DISTINCT FROM new.summary) OR (old.full_body IS DISTINCT FROM new.full_body) OR (old.sop_id IS DISTINCT FROM new.sop_id))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: sop_registry trg_sop_registry_delete_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_sop_registry_delete_si AFTER DELETE ON factory.sop_registry FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: sop_registry trg_sop_registry_seed_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_sop_registry_seed_si AFTER INSERT ON factory.sop_registry FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: tasks trg_tasks_content_change; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_tasks_content_change AFTER UPDATE OF title, description, category ON factory.tasks FOR EACH ROW WHEN ((((old.title)::text IS DISTINCT FROM (new.title)::text) OR (old.description IS DISTINCT FROM new.description) OR ((old.category)::text IS DISTINCT FROM (new.category)::text))) EXECUTE FUNCTION public.fn_mark_embedding_stale();


--
-- Name: tasks trg_tasks_delete_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_tasks_delete_si AFTER DELETE ON factory.tasks FOR EACH ROW EXECUTE FUNCTION public.fn_delete_semantic_index_for_source();


--
-- Name: tasks trg_tasks_seed_si; Type: TRIGGER; Schema: factory; Owner: -
--

CREATE TRIGGER trg_tasks_seed_si AFTER INSERT ON factory.tasks FOR EACH ROW EXECUTE FUNCTION public.fn_seed_semantic_index();


--
-- Name: research research_session_id_fkey; Type: FK CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.research
    ADD CONSTRAINT research_session_id_fkey FOREIGN KEY (session_id) REFERENCES factory.factory_sessions(id) ON DELETE SET NULL;


--
-- Name: research research_superseded_by_fkey; Type: FK CONSTRAINT; Schema: brain; Owner: -
--

ALTER TABLE ONLY brain.research
    ADD CONSTRAINT research_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES brain.research(id) ON DELETE SET NULL;


--
-- Name: content_staging content_staging_research_id_fkey; Type: FK CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.content_staging
    ADD CONSTRAINT content_staging_research_id_fkey FOREIGN KEY (research_id) REFERENCES brain.research(id) ON DELETE SET NULL;


--
-- Name: content_staging content_staging_session_id_fkey; Type: FK CONSTRAINT; Schema: brand; Owner: -
--

ALTER TABLE ONLY brand.content_staging
    ADD CONSTRAINT content_staging_session_id_fkey FOREIGN KEY (session_id) REFERENCES factory.factory_sessions(id) ON DELETE SET NULL;


--
-- Name: agent_identity agent_identity_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.agent_identity
    ADD CONSTRAINT agent_identity_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.agent_state(agent_name) ON UPDATE CASCADE;


--
-- Name: persona fk_persona_current_version; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona
    ADD CONSTRAINT fk_persona_current_version FOREIGN KEY (current_version) REFERENCES factory.persona_version(id);


--
-- Name: persona_archetype persona_archetype_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_archetype
    ADD CONSTRAINT persona_archetype_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_asset persona_asset_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_asset
    ADD CONSTRAINT persona_asset_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name) ON DELETE CASCADE;


--
-- Name: persona_build persona_build_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_build
    ADD CONSTRAINT persona_build_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name);


--
-- Name: persona_build persona_build_persona_version_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_build
    ADD CONSTRAINT persona_build_persona_version_fkey FOREIGN KEY (persona_version) REFERENCES factory.persona_version(id);


--
-- Name: persona_character_bible persona_character_bible_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_bible
    ADD CONSTRAINT persona_character_bible_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_character_dimension persona_character_dimension_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_character_dimension
    ADD CONSTRAINT persona_character_dimension_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_drift_check persona_drift_check_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_drift_check
    ADD CONSTRAINT persona_drift_check_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name) ON DELETE CASCADE;


--
-- Name: persona_drift_check persona_drift_check_export_target_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_drift_check
    ADD CONSTRAINT persona_drift_check_export_target_id_fkey FOREIGN KEY (export_target_id) REFERENCES factory.persona_export_target(id) ON DELETE CASCADE;


--
-- Name: persona_drift_check persona_drift_check_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_drift_check
    ADD CONSTRAINT persona_drift_check_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE SET NULL;


--
-- Name: persona_eval_criteria persona_eval_criteria_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_eval_criteria
    ADD CONSTRAINT persona_eval_criteria_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name);


--
-- Name: persona_export_target persona_export_target_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_export_target
    ADD CONSTRAINT persona_export_target_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name) ON DELETE CASCADE;


--
-- Name: persona_export_target persona_export_target_generated_from_version_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_export_target
    ADD CONSTRAINT persona_export_target_generated_from_version_fkey FOREIGN KEY (generated_from_version) REFERENCES factory.persona_version(id);


--
-- Name: persona_lane_contract persona_lane_contract_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_lane_contract
    ADD CONSTRAINT persona_lane_contract_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_provenance persona_provenance_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_provenance
    ADD CONSTRAINT persona_provenance_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name) ON DELETE CASCADE;


--
-- Name: persona_provenance persona_provenance_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_provenance
    ADD CONSTRAINT persona_provenance_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_strength persona_strength_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_strength
    ADD CONSTRAINT persona_strength_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_tool persona_tool_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_tool
    ADD CONSTRAINT persona_tool_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: persona_version persona_version_agent_name_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_version
    ADD CONSTRAINT persona_version_agent_name_fkey FOREIGN KEY (agent_name) REFERENCES factory.persona(agent_name) ON DELETE CASCADE;


--
-- Name: persona_voice_contract persona_voice_contract_version_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.persona_voice_contract
    ADD CONSTRAINT persona_voice_contract_version_id_fkey FOREIGN KEY (version_id) REFERENCES factory.persona_version(id) ON DELETE CASCADE;


--
-- Name: retrieval_eval_results retrieval_eval_results_case_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_results
    ADD CONSTRAINT retrieval_eval_results_case_id_fkey FOREIGN KEY (case_id) REFERENCES factory.retrieval_eval_cases(case_id) ON DELETE CASCADE;


--
-- Name: retrieval_eval_results retrieval_eval_results_run_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.retrieval_eval_results
    ADD CONSTRAINT retrieval_eval_results_run_id_fkey FOREIGN KEY (run_id) REFERENCES factory.retrieval_eval_runs(run_id) ON DELETE CASCADE;


--
-- Name: rimmer_runs rimmer_runs_session_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.rimmer_runs
    ADD CONSTRAINT rimmer_runs_session_id_fkey FOREIGN KEY (session_id) REFERENCES factory.factory_sessions(id) ON DELETE SET NULL;


--
-- Name: session_mcp_status session_mcp_status_connector_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_mcp_status
    ADD CONSTRAINT session_mcp_status_connector_id_fkey FOREIGN KEY (connector_id) REFERENCES factory.mcp_registry(connector_id) ON UPDATE CASCADE;


--
-- Name: session_mcp_status session_mcp_status_session_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.session_mcp_status
    ADD CONSTRAINT session_mcp_status_session_id_fkey FOREIGN KEY (session_id) REFERENCES factory.factory_sessions(id) ON DELETE CASCADE;


--
-- Name: sop_steps sop_steps_sop_id_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.sop_steps
    ADD CONSTRAINT sop_steps_sop_id_fkey FOREIGN KEY (sop_id) REFERENCES factory.sop_registry(sop_id) ON DELETE CASCADE;


--
-- Name: tasks tasks_blocked_by_fkey; Type: FK CONSTRAINT; Schema: factory; Owner: -
--

ALTER TABLE ONLY factory.tasks
    ADD CONSTRAINT tasks_blocked_by_fkey FOREIGN KEY (blocked_by) REFERENCES factory.tasks(id);


--
-- PostgreSQL database dump complete
--

\unrestrict tdKnhmigJeJxBsRQQgPmJopeXyHehkcwWkYdHwYTEbjasYJOsAcjdyKSyRs4fBH


--
-- O-Matic gold standard: private kernel, public interface only.
-- Kernel schemas are not reachable by unprivileged roles; access is via public views/functions.
--
REVOKE USAGE ON SCHEMA factory, brain, brand FROM PUBLIC;
