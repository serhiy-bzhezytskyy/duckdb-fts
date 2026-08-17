CREATE MACRO {{fts_schema}}.search_layered_bm25(query_string, fields := NULL, top_k := 50, k := 1.2, b := 0.75, term_limit := 32, max_df_ratio := 0.15, max_df := 50000, enable_prefix := true, enable_substring := true, enable_fuzzy := true, enable_short_fuzzy := true, expand_exact_terms := false, query_mode := 'standard', field_weights := NULL, field_b := NULL, scoring_model := 'bm25f', tie_breaker := 0.0, near_distance := 10) AS TABLE
SELECT *
FROM {{fts_schema}}.__search_layered_bm25_non_pattern(
    query_string,
    fields := fields,
    top_k := top_k,
    k := k,
    b := b,
    term_limit := term_limit,
    max_df_ratio := max_df_ratio,
    max_df := max_df,
    enable_prefix := enable_prefix,
    enable_substring := enable_substring,
    enable_fuzzy := enable_fuzzy,
    enable_short_fuzzy := enable_short_fuzzy,
    expand_exact_terms := expand_exact_terms,
    near_distance := near_distance,
    query_mode := query_mode,
    field_weights := field_weights,
    field_b := field_b,
    scoring_model := scoring_model,
    tie_breaker := tie_breaker
)
WHERE query_mode IS NULL
   OR lower(query_mode::VARCHAR) NOT IN ('wildcard', 'regex')
UNION ALL
SELECT *
FROM {{fts_schema}}.__search_layered_pattern(
    query_string,
    fields := fields,
    top_k := top_k,
    b := b,
    query_mode := query_mode,
    field_weights := field_weights,
    field_b := field_b,
    scoring_model := scoring_model,
    tie_breaker := tie_breaker
)
WHERE lower(query_mode::VARCHAR) IN ('wildcard', 'regex')
ORDER BY rank;
