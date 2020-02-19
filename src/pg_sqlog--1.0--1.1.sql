CREATE OR REPLACE FUNCTION sqlog.preparable_query(message text) RETURNS text AS $$
  SELECT
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE($1, '^(duration: [^:]+ (<unnamed>|statement|execute [^:]+): +)?', ''),
          '('')[\d\w\.:\-\+ ]+('')',
          E'\\1?\\2',
          'g'
        ),
        '([^\d])\d+([^\d])?',
        E'\\1?\\2',
        'g'
      ),
      '([^A-Za-z_]IN[^A-Za-z_]*\()[\''\?, ]+(\))',
      E'\\1?\\2',
      'g'
    );
$$ LANGUAGE sql IMMUTABLE STRICT;
