-- Wikimedia Commons as a source (functions/olo-ingest/wikimedia_commons.ts, issue #1).
-- Starts disabled: a person enables it after the deployed connector has been
-- watched for a run or two
-- (update public.olo_sources set enabled = true where slug = 'wikimedia_commons').
-- Safe to run again: an existing row is left as it is.
--
-- What is stored: the English caption written for a quality image on Commons, with
-- its title, author, date and the file page URL; never the image. The caption is
-- wiki text, CC BY-SA 4.0 under the Wikimedia terms of use. The file's own licence
-- is checked per file and recorded on each atom; only CC0, public domain, CC BY and
-- CC BY-SA files are kept (GFDL-only and other licences are dropped).
-- Trust 70: captions are written by uploaders and reviewed for image quality, not
-- for accuracy, so they sit below the encyclopedias and the papers.

insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled) values
 ('wikimedia_commons', 'Wikimedia Commons', 'archive', 'https://commons.wikimedia.org', 'https://commons.wikimedia.org/w/api.php',
  'CC BY-SA 4.0 (captions); per file, kept only when the file is CC0, public domain, CC BY or CC BY-SA',
  'https://commons.wikimedia.org/wiki/Commons:Licensing',
  'Captions of freely licensed quality images on Wikimedia Commons, with author, date and a link to the file page.', 70, false)
on conflict (slug) do nothing;
