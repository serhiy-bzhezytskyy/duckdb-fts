CREATE MACRO {{fts_schema}}.__search_layered_pattern(query_string, fields := NULL, top_k := 50, b := 0.75, query_mode := 'wildcard', field_weights := NULL, field_b := NULL, scoring_model := 'bm25f', tie_breaker := 0.0) AS TABLE
WITH params(field_weights, field_b, scoring_model, tie_breaker, default_b) AS (
    SELECT field_weights::MAP(VARCHAR, DOUBLE),
           field_b::MAP(VARCHAR, DOUBLE),
           lower(scoring_model::VARCHAR),
           tie_breaker::DOUBLE,
           b::DOUBLE
),
{{field_scoring_config_ctes}}
fts_extension_autoload AS (
    -- Bind DuckDB's stable FTS autoload entry before the internal analyzer.
    SELECT stem('', 'none') AS marker
),
pattern_analysis AS (
    SELECT analysis.verification_pattern,
           analysis.lookup_kind,
           analysis.lookup_literal,
           analysis.error_message
    FROM fts_extension_autoload
    CROSS JOIN LATERAL (
        SELECT fts_analyze_pattern(
                   query_string,
                   lower(query_mode::VARCHAR)
               ) AS analysis
    ) AS analyzed
),
search_validation_errors AS (
    SELECT message
    FROM (
        SELECT 10 AS priority,
               error_message AS message
        FROM pattern_analysis
        WHERE error_message IS NOT NULL
        UNION ALL
        SELECT 20 AS priority,
               message
        FROM validation_errors
    ) AS raw_search_validation_errors
    ORDER BY priority,
             message
    LIMIT 1
),
pattern_prefix_input AS (
    SELECT least(length(lookup_literal), 3)::UTINYINT AS prefix_len,
           substr(lookup_literal, 1, least(length(lookup_literal), 3)) AS prefix,
           lookup_literal
    FROM pattern_analysis
    WHERE lookup_kind = 'prefix'
),
pattern_prefix_candidates AS (
    SELECT term_prefixes.rawtermid
    FROM pattern_prefix_input AS pattern_prefix
    JOIN {{fts_schema}}.term_prefixes AS term_prefixes
      ON term_prefixes.prefix_len = pattern_prefix.prefix_len
     AND term_prefixes.prefix = pattern_prefix.prefix
    JOIN {{fts_schema}}.raw_dict AS raw_dict
      ON raw_dict.rawtermid = term_prefixes.rawtermid
    WHERE starts_with(raw_dict.raw_term, pattern_prefix.lookup_literal)
),
pattern_query_grams AS (
    SELECT DISTINCT 'g' || lower(hex(substr(lookup_literal, i, 3))) AS gram
    FROM pattern_analysis,
         range(1, length(lookup_literal) - 1) AS r(i)
    WHERE lookup_kind = 'gram'
),
pattern_gram_candidates AS (
    SELECT raw_term_grams.rawtermid
    FROM pattern_query_grams
    JOIN {{fts_schema}}.raw_term_grams AS raw_term_grams USING (gram)
    GROUP BY raw_term_grams.rawtermid
    HAVING count(*) = (SELECT count(*) FROM pattern_query_grams)
),
pattern_term_gram_candidates AS (
    SELECT raw_dict.rawtermid
    FROM pattern_query_grams
    JOIN {{fts_schema}}.term_grams AS term_grams USING (gram)
    JOIN {{fts_schema}}.term_stats AS term_stats USING (termid)
    JOIN {{fts_schema}}.raw_dict AS raw_dict
      ON raw_dict.termid = term_stats.termid
     AND raw_dict.raw_term = term_stats.term
    GROUP BY raw_dict.rawtermid
    HAVING count(DISTINCT pattern_query_grams.gram)
        = (SELECT count(*) FROM pattern_query_grams)
),
pattern_candidate_rawterms AS (
    SELECT rawtermid
    FROM pattern_prefix_candidates
    UNION ALL
    SELECT rawtermid
    FROM pattern_gram_candidates
    UNION ALL
    SELECT rawtermid
    FROM pattern_term_gram_candidates
),
verified_pattern_terms AS (
    SELECT raw_dict.rawtermid
    FROM pattern_candidate_rawterms
    JOIN {{fts_schema}}.raw_dict AS raw_dict USING (rawtermid)
    CROSS JOIN pattern_analysis
    WHERE regexp_full_match(
        raw_dict.raw_term,
        pattern_analysis.verification_pattern
    )
),
pattern_field_matches AS (
    SELECT DISTINCT terms.docid,
                    terms.fieldid,
                    field_config.field_weight
    FROM verified_pattern_terms
    JOIN {{fts_schema}}.terms AS terms USING (rawtermid)
    JOIN field_config USING (fieldid)
),
scores AS (
    SELECT pattern_field_matches.docid,
           CASE params.scoring_model
               WHEN 'bm25f' THEN sum(pattern_field_matches.field_weight)
               ELSE max(pattern_field_matches.field_weight)
                   + params.tie_breaker * (
                       sum(pattern_field_matches.field_weight)
                       - max(pattern_field_matches.field_weight)
                   )
           END::DOUBLE AS score
    FROM pattern_field_matches
    CROSS JOIN params
    GROUP BY pattern_field_matches.docid,
             params.scoring_model,
             params.tie_breaker
),
ranked AS (
    SELECT docs.name AS docname,
           scores.score,
           row_number() OVER (ORDER BY scores.score DESC, docs.name) AS rank
    FROM scores
    JOIN {{fts_schema}}.docs AS docs ON docs.docid = scores.docid
),
results AS (
    SELECT docname,
           score,
           rank
    FROM ranked
    WHERE top_k IS NULL
       OR rank <= top_k
)
SELECT *
FROM results
UNION ALL
-- Every column carries the error: a pushed predicate on a constant column
-- would fold to false and drop this branch before its filter runs.
SELECT CASE WHEN error(message) THEN NULL::VARCHAR END AS docname,
       CASE WHEN error(message) THEN NULL::DOUBLE END AS score,
       CASE WHEN error(message) THEN NULL::BIGINT END AS rank
FROM search_validation_errors
WHERE error(message)
ORDER BY rank;
