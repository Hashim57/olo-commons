-- Olo Commons: remove the Internet Archive atoms that came from the uploader
-- shelves and the genealogy indexes, and the catalogue pages two European
-- libraries copy into their descriptions.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/025.
-- Safe to run again: "create or replace" and deletes that find nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the replaced function stays server-only with explicit grants and revokes.
--
-- Why (1): the narrower archive_org search deployed on 25 November 2026
-- (licence asked for in the query, most downloaded first) raised the source
-- from 6 to 70 atoms a day, and 49 of the 70 stored between 12:48 UTC on 25
-- November and 13:33 UTC on 26 November sit on the Archive's other uploader
-- shelves: booksbylanguage and folkscanomy (the Community Texts uploads
-- re-shelved by language and by subject, under whatever licence the uploader
-- typed: a 2007 novel and a 2020 bestseller under CC0, a 2016 dictionary
-- under CC BY, a pirate "PDF GRATIS" page, two antisemitic tracts and a 1940
-- propaganda film, a state payroll list of 84,000 named employees),
-- newsstand and magazine_rack (the same for periodicals), fringe and
-- deemphasize (the Archive's own marks for items it keeps out of its search)
-- and reclaimtherecords (marriage certificates of named private people). Each
-- item's collections were read from the Archive's search on 26 November. The
-- ingester leaves those shelves out of the query from the same date
-- (ARCHIVE_EXCLUDED_COLLECTIONS in functions/olo-ingest/sources.ts); this file
-- removes the 49 by URL, archive_org only. The 21 others stored that day
-- (National Security Archive, americana, university libraries, reference,
-- manuals) stay.
--
-- Why (2): the Bibliotheque Sainte-Genevieve and the Biblioteca de la
-- Universidad de Sevilla describe their scans with their own catalogue page:
-- "Cote du document : DELTA 53987 FA 2 tomes ... Notice Sudoc" and "Mas
-- detalles PUBLICACION Madrid : Viuda de Hernando, 1892 DESCR. FISICA 424 p. ;
-- 19 cm ... SIGNATURA B Res.140146 Catalogo Fama" (accents dropped here, kept in the stored text). What
-- such a body says beyond the title is a shelf mark and a page count, which no
-- claim is checked against. isLibraryRecord in functions/olo-ingest/text.ts
-- refuses them from the same date; olo_is_library_record below gains the same
-- two rules. Checked against all 15,820 texts of the live Commons on 26
-- November 2026 (read through the public REST API) with the TypeScript rule:
-- 11 archive_org atoms match (the 6 Library of Congress records of sql/023,
-- 3 from Sevilla, 2 from Sainte-Genevieve) and no atom of any other source.

-- ---------------------------------------------------------------------------
-- 1. The 49 shelf items, by exact URL and from archive_org only, so nothing
--    else can go. The statement reports how many it removed: 49 the first
--    time, 0 after. Links and sightings go with each atom (foreign keys with
--    on delete cascade, sql/001 and sql/002).
-- ---------------------------------------------------------------------------
with shelf(url) as (values
  ('https://archive.org/details/19740102tribuna'),  -- newsstand: Diario Tribuna
  ('https://archive.org/details/20230520_20230520_2044'),  -- booksbylanguage: দ্য সাইকোলজি অব মানি
  ('https://archive.org/details/20240423_20240423_0152'),  -- booksbylanguage: مكتبة الكتب جلسات نفسية
  ('https://archive.org/details/aalam_almaarifa'),  -- booksbylanguage: عالم المعرفة
  ('https://archive.org/details/adam-smith-la-riqueza-de-las-naciones_202304'),  -- folkscanomy: Adam Smith La Riqueza De Las Naciones
  ('https://archive.org/details/Afrodita-En-La-Cama-Pdf-Gratis'),  -- booksbylanguage: AFRODITA EN LA CAMA PDF GRATIS
  ('https://archive.org/details/american-magazine'),  -- magazine_rack: American Magazine, The 1905-1930
  ('https://archive.org/details/AppuntiDiInformaticaLibera'),  -- booksbylanguage: «a2», ex «Appunti di informatica libera», ex «Appunti L
  ('https://archive.org/details/Ashtanga.Hridaya.of.Vagbhata'),  -- booksbylanguage: Ashtanga Hridaya of Vagbhata - with 2 Commentaries [San
  ('https://archive.org/details/Astounding_Stories_of_Super_Science_1932'),  -- magazine_rack: Astounding Stories 1932
  ('https://archive.org/details/BhavarthRamayan'),  -- booksbylanguage: Bhavarth Ramayan
  ('https://archive.org/details/BibleDictionary.williamSmithEditor.HackettAbbotFullerEtc.American'),  -- folkscanomy: Bible Dictionary.William Smith, Editor. Hackett, Abbot,
  ('https://archive.org/details/BiblicalCollectionPrintedBetween1600-1800'),  -- folkscanomy: Biblical Collection (Printed Between 1600-1800)
  ('https://archive.org/details/boggen-forest-man'),  -- booksbylanguage: Bloggen Forest Man. Del 1.
  ('https://archive.org/details/call-me-by-your-name-andre-aciman'),  -- folkscanomy: Call Me By Your Name, A Novel
  ('https://archive.org/details/ChhatrapatiShivajiMaharaj'),  -- booksbylanguage: Chhatrapati Shivaji Maharaj
  ('https://archive.org/details/CommentaryOnTheHolyScripturesCriticalDoctrinalAndHomilectical.Lange'),  -- folkscanomy: Commentary on the Holy Scriptures, Critical, Doctrinal 
  ('https://archive.org/details/CommonwealthOfPennsylvaniaPayrollDatabase2008'),  -- folkscanomy: Commonwealth of Pennsylvania payroll database 2008
  ('https://archive.org/details/complutensianpolyglot'),  -- folkscanomy: Complutensian Polyglot Bible (HD)
  ('https://archive.org/details/DerEwigeJude1940'),  -- booksbylanguage: Der Ewige Jude (The Eternal Jew), 1940 - w/English Subt
  ('https://archive.org/details/DioCassiusRomanHistory9books7180WithIndices'),  -- booksbylanguage: Dio Cassius Roman History (Loeb Classical Library in 9 
  ('https://archive.org/details/DocumentsFromTheU.s.EspionageDen'),  -- booksbylanguage: Documents from the U.S. Espionage Den
  ('https://archive.org/details/ElementryLinearAlgebraByHowardAnton10thEdition'),  -- folkscanomy: Elementry Linear Algebra By Howard Anton 10th Edition
  ('https://archive.org/details/EncyclopaediaBritannicaDict.a.s.l.g.i.11thed.chisholm.1910-1911-1922.33vols'),  -- folkscanomy: Encyclopaedia Britannica Dict.A.S.L.G.I.11thEd.Chisholm
  ('https://archive.org/details/Fsi-GermanProgrammedIntroduction-StudentText'),  -- folkscanomy: FSI - German Programmed Introduction - Student Text
  ('https://archive.org/details/Fsi-HebrewBasicCourse-StudentText'),  -- folkscanomy: FSI - Hebrew Basic Course - Student Text
  ('https://archive.org/details/hemingway_202012'),  -- folkscanomy: The Complet Short Story by Ernest Hemingway
  ('https://archive.org/details/HolyQuranByMuhammadMarmadukePickthallPdf'),  -- folkscanomy: Holy Quran By Muhammad Marmaduke Pickthall Pdf
  ('https://archive.org/details/JewsDeclareWarOnGermany1933'),  -- deemphasize: Jews Declare War on Germany 1933
  ('https://archive.org/details/MassorahMassorethMassoretic'),  -- folkscanomy: Massorah Massoreth Massoretic RabbinicHebrewBible.C.D.G
  ('https://archive.org/details/modern-chinese-dictionary_7th-edition'),  -- booksbylanguage: 现代汉语词典（第七版）
  ('https://archive.org/details/modern-mechanics-scantailored-microfilm'),  -- magazine_rack: Modern Mechanics/Mechanix Illustrated
  ('https://archive.org/details/pdf4kurd_adabiyat'),  -- booksbylanguage: ئەدەبیات - PDF4Kurd
  ('https://archive.org/details/pdf4kurd_roman1'),  -- booksbylanguage: 1 ڕۆمان - PDF4Kurd
  ('https://archive.org/details/PhiloSupplement01Genesis'),  -- booksbylanguage: Philo of Alexandria, Works (Loeb Classical Library in 1
  ('https://archive.org/details/PlantasDeLosDioses'),  -- booksbylanguage: Plantas de los dioses. OrÃ­genes del uso de los alucinÃ
  ('https://archive.org/details/reclaim-the-records-maryland-marriage-certificates-s-1864-3101'),  -- reclaimtherecords: Maryland Marriage Certificates 1987-1988 S1864 3101-320
  ('https://archive.org/details/RecordResearchMagazine'),  -- magazine_rack: Record Research Magazine
  ('https://archive.org/details/rXra_ravan-samhita-asli-pracheen-by-pt.-kishan-lal-sharma-manoj-publications-delhi'),  -- booksbylanguage: Ravan Samhita ( Asli Pracheen) By Pt. Kishan Lal Sharma
  ('https://archive.org/details/tafsir-ibnu-katsir-juz-i'),  -- folkscanomy: Tafsir Ibnu Katsir Indonesian
  ('https://archive.org/details/TheAmericanMagazineV70n06191010'),  -- magazine_rack: The American Magazine v70n06 [1910-10]
  ('https://archive.org/details/TheInternationalJew_655'),  -- newsstand: THE INTERNATIONAL JEW
  ('https://archive.org/details/TVSdictionary'),  -- booksbylanguage: TAMIL-ENGLISH DICTIONARY OF MEDICINE, CHEMISTRY, BOTANY
  ('https://archive.org/details/U.s.DepartmentOfAgricultureEmployeeRosterAndSalaryList2008'),  -- folkscanomy: U.S. Department of Agriculture employee roster and sala
  ('https://archive.org/details/UrduBooksCollection'),  -- booksbylanguage: Urdu Books Collection
  ('https://archive.org/details/vrajeshkumar_gmail_061'),  -- booksbylanguage: Kamba Ramayanam [Full text with commentary] - கம்ப ராமா
  ('https://archive.org/details/WaltPoly1PrologVariantReadings'),  -- folkscanomy: Brian Walton Polyglot
  ('https://archive.org/details/YantraMantraTantraVidya'),  -- booksbylanguage: Yantra, Mantra, Tantra Vidya
  ('https://archive.org/details/yhSx_oxford-current-english-grammar-by-r.-k.-sinha-1996-patna-good-man-p-d')  -- booksbylanguage: Oxford Current English Grammar By R. K. Sinha 1996 Patn
), gone as (
  delete from public.olo_atoms a
  using public.olo_sources s, shelf
  where s.id = a.source_id and s.slug = 'archive_org' and a.url = shelf.url
  returning a.id
)
select count(*) as shelf_items_removed from gone;

-- ---------------------------------------------------------------------------
-- 2. olo_is_library_record gains the two European catalogue copies, the same
--    test as isLibraryRecord() in text.ts: a "Cote du document :" field or a
--    Sudoc notice anywhere in the body, or a body that opens with "Mas
--    detalles" (accented as stored) and names a field of the Fama catalogue.
--    Postgres writes a word boundary as \y, not \b. The Library of Congress
--    test of sql/023 is unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_library_record(p_summary text, p_content text)
returns boolean language plpgsql immutable as $$
declare
  header_re constant text := '(^|\s)(MEDIUM|CREATED / PUBLISHED|CONTRIBUTOR NAMES|SUBJECTS|NOTES|FORMAT|SOURCE|REPOSITORY|REPRODUCTION NUMBER|CALL NUMBER|DIGITAL ID|LCCN|CREDIT|RIGHTS|PROVENANCE|PART OF)(?=\s)';
  rights_re constant text := '\m(public domain|copyright(ed)?|all rights reserved|no known (copyright )?restrictions|metadata|crossref|source url|full record)\M';
  shelf_field_re constant text := '\yCote du document\s*:|\yNotice (dans le )?Sudoc\y';
  details_re constant text := '^Más detalles\y';
  fama_field_re constant text := '\y(SIGNATURA|DESCR\. FÍSICA|CLASIFICAC\.)\s|\yCatálogo Fama\y';
  body text;
  h int;
  n_headers int;
  first_at int;
  s text;
begin
  body := case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end;
  body := btrim(regexp_replace(body, '\s+', ' ', 'g'));
  if body = '' then return false; end if;
  -- a text written twice in a row, read once
  h := (length(body) - 1) / 2;
  if length(body) > 40 and substr(body, h + 1, 1) = ' ' and left(body, h) = substr(body, h + 2) then body := left(body, h); end if;
  -- the Sainte-Genevieve and Sevilla catalogue pages (case sensitive, as in text.ts)
  if body ~ shelf_field_re or (body ~ details_re and body ~ fama_field_re) then return true; end if;
  -- distinct headers (the regex is case sensitive: the capitals are the point)
  select count(distinct m[2]) into n_headers from regexp_matches(body, header_re, 'g') as m;
  if coalesce(n_headers, 0) < 3 then return false; end if;
  -- where the first header itself starts (subexpression 2; the match may begin with the space before it), 0-based as in text.ts
  first_at := regexp_instr(body, header_re, 1, 1, 0, '', 2) - 1;
  if first_at > 120 then return false; end if;
  -- a rights sentence somewhere
  foreach s in array regexp_split_to_array(body, '[.!?]\s+') loop
    if s ~* rights_re then return true; end if;
  end loop;
  return false;
end
$$;

revoke execute on function public.olo_is_library_record(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_library_record(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. What would go, by source. Read it first: expect archive_org only, 11 the
--    first time (5 the first time if sql/023 already ran), 0 after step 4.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as library_records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_library_record(a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 4. Delete the archive_org library records and keep the per-source counts
--    the page shows in step with the table.
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_library_record(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

-- Check after running: step 1 reports 0 and step 3 returns no rows the second time.
