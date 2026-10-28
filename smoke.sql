\set ON_ERROR_STOP on
CREATE EXTENSION vector VERSION '0.8.2';
DO $$ BEGIN
 IF current_setting('server_version') <> '17.11' THEN RAISE EXCEPTION 'wrong server'; END IF;
 IF (SELECT extversion FROM pg_extension WHERE extname='vector') <> '0.8.2' THEN RAISE EXCEPTION 'wrong extension'; END IF;
 IF '[1,2,3]'::vector <-> '[1,2,3]'::vector <> 0 THEN RAISE EXCEPTION 'L2 self'; END IF;
 IF abs(('[1,2,3]'::vector <-> '[4,6,3]'::vector)-5) > 0.00001 THEN RAISE EXCEPTION 'L2'; END IF;
 IF '[1,2,3]'::vector <#> '[4,5,6]'::vector <> -32 THEN RAISE EXCEPTION 'inner product'; END IF;
 IF abs(('[1,0,0]'::vector <=> '[0,1,0]'::vector) - 1) > 0.00001 THEN RAISE EXCEPTION 'cosine'; END IF;
 IF vector_dims('[1,2,3]'::vector) <> 3 THEN RAISE EXCEPTION 'dimensions'; END IF;
 IF '[1,2,3]'::halfvec <-> '[1,2,3]'::halfvec <> 0 THEN RAISE EXCEPTION 'halfvec'; END IF;
 IF '{1:1,3:2}/3'::sparsevec <-> '{1:1,3:2}/3'::sparsevec <> 0 THEN RAISE EXCEPTION 'sparsevec'; END IF;
END $$;
CREATE TABLE public.synthetic_vectors (id integer PRIMARY KEY, embedding vector(3));
INSERT INTO public.synthetic_vectors VALUES (1,'[1,2,3]'),(2,'[4,5,6]'),(3,'[7,8,9]');
CREATE INDEX synthetic_hnsw ON public.synthetic_vectors USING hnsw (embedding vector_l2_ops);
SET enable_seqscan=off;
EXPLAIN (COSTS OFF) SELECT id FROM public.synthetic_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1;
DO $$ BEGIN
 IF (SELECT id FROM public.synthetic_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1) <> 1 THEN RAISE EXCEPTION 'hnsw result'; END IF;
END $$;
DROP INDEX public.synthetic_hnsw;
CREATE INDEX synthetic_ivfflat ON public.synthetic_vectors USING ivfflat (embedding vector_l2_ops) WITH (lists=1);
EXPLAIN (COSTS OFF) SELECT id FROM public.synthetic_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1;
DO $$ BEGIN
 IF (SELECT id FROM public.synthetic_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1) <> 1 THEN RAISE EXCEPTION 'ivfflat result'; END IF;
END $$;
RESET enable_seqscan;
SELECT version(), current_setting('server_version_num'), extversion FROM pg_extension WHERE extname='vector';
SELECT 'PGVECTOR_REMOTE_SMOKE_PASS';
