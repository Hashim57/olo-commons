# examples/notebook.py
# Pull every atom on a topic into a pandas DataFrame with provenance columns.
#   pip install requests pandas
#   python examples/notebook.py "ocean acidification"
import sys, requests, pandas as pd

OLO = 'https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-query'
topic = ' '.join(sys.argv[1:]) or 'ocean acidification'

rows = requests.post(OLO, json={'q': topic, 'k': 20}, timeout=30).json()['results']
df = pd.DataFrame(rows)[['title', 'source', 'licence', 'published_at', 'retrieved_at', 'similarity', 'url', 'summary']]
print(df.head(20).to_string())
df.to_csv('olo_' + topic.replace(' ', '_') + '.csv', index=False)
print(f"\n{len(df)} atoms saved. Each row carries its own licence; cite the url.")
