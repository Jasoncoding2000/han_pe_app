"""
Local replication of the hanPE app's COMPOSITE ROTATION screener.
Uses the SAME live Sina API endpoints as the Flutter app to verify results.
Algorithm: worst = max(hanPE, hanPB), rank all valid stocks, show top-20.
"""
import sys, json, re, time
import urllib.request
import numpy as np

sys.stdout.reconfigure(encoding='utf-8')

SINA_BASE = 'https://vip.stock.finance.sina.com.cn'
HEADERS = {'User-Agent': 'Mozilla/5.0'}

def get_gbk(path, retries=3):
    url = SINA_BASE + path
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read()
            return raw.decode('gbk', errors='replace')
        except Exception as e:
            print(f'  [HTTP] attempt {attempt}/{retries} failed: {e}')
            if attempt < retries:
                time.sleep(attempt)
    return None

def fetch_sectors():
    text = get_gbk('/q/view/newSinaHy.php')
    if not text:
        return []
    json_str = text[text.index('{'):]
    data = json.loads(json_str)
    sectors = []
    for label, value in data.items():
        parts = value.split(',')
        sectors.append({'label': label, 'name': parts[1] if len(parts) > 1 else label})
    return sectors

def fetch_sector_stocks(node, industry_name):
    stocks = []
    page = 1
    num = 80
    while True:
        path = f'/quotes_service/api/json_v2.php/Market_Center.getHQNodeData?page={page}&num={num}&sort=symbol&asc=1&node={node}&_s_r_a=page'
        body = get_gbk(path)
        if not body:
            break
        try:
            data = json.loads(body)
        except Exception:
            break
        if not data:
            break
        for item in data:
            symbol = re.sub(r'^(sh|sz)', '', item.get('symbol', ''))
            code = symbol.zfill(6)
            def sfld(v):
                try: return float(v) if v and v != '-' else None
                except: return None
            price = sfld(item.get('trade'))
            pe = sfld(item.get('per'))
            pb = sfld(item.get('pbs')) or sfld(item.get('pb'))
            turnover = sfld(item.get('turnoverratio'))
            name = item.get('name', '')
            if price is not None and pe is not None and turnover is not None:
                stocks.append({'code': code, 'name': name, 'price': price,
                               'pe': pe, 'pb': pb or 0, 'turnover': turnover,
                               'industry': industry_name})
        if len(data) < num:
            break
        page += 1
    return stocks

def median(v):
    s = sorted(v)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m-1] + s[m]) / 2.0

def main():
    print('=== Composite Rotation Screener (replicating app logic) ===\n')
    print('Fetching industry sectors...')
    sectors = fetch_sectors()
    print(f'  Found {len(sectors)} sectors')

    all_stocks = []
    for i, s in enumerate(sectors):
        if (i+1) % 10 == 0 or i == 0:
            print(f'  [{i+1}/{len(sectors)}] {s["name"]}...', flush=True)
        stocks = fetch_sector_stocks(s['label'], s['name'])
        all_stocks.extend(stocks)
    print(f'  Total stocks fetched: {len(all_stocks)}')

    # Filter universe (same as app: 60/00[0-3] codes, no ST, price>0, industry non-empty)
    df = [r for r in all_stocks
          if re.match(r'^(60|00[0-3])', r['code'])
          and not re.search(r'ST|st|\*ST|退', r['name'], re.IGNORECASE)
          and r['price'] > 0 and r['industry']]
    print(f'  After universe filter: {len(df)}')

    # Compute industry median PE and PB
    pe_groups = {}
    pb_groups = {}
    for r in df:
        ind = r['industry']
        if r['pe'] > 0:
            pe_groups.setdefault(ind, []).append(r['pe'])
        if r['pb'] > 0:
            pb_groups.setdefault(ind, []).append(r['pb'])
    med_pe = {k: median(v) for k, v in pe_groups.items()}
    med_pb = {k: median(v) for k, v in pb_groups.items()}

    # Compute worst = max(hanPE, hanPB) for stocks where both valid
    valid = []
    for r in df:
        if r['pe'] <= 0 or r['pb'] <= 0:
            continue
        mp = med_pe.get(r['industry'])
        mb = med_pb.get(r['industry'])
        if not mp or not mb or mp <= 0 or mb <= 0:
            continue
        hanpe = r['pe'] / mp
        hanpb = r['pb'] / mb
        worst = max(hanpe, hanpb)
        if worst > 0 and np.isfinite(worst):
            valid.append({**r, 'hanpe': hanpe, 'hanpb': hanpb, 'worst': worst,
                          'med_pe': mp, 'med_pb': mb})

    # Rank by worst ascending
    valid.sort(key=lambda x: x['worst'])
    for i, v in enumerate(valid):
        v['rank'] = i + 1

    # Deduplicate by code (keep cheapest)
    best = {}
    for v in valid:
        if v['code'] not in best or v['worst'] < best[v['code']]['worst']:
            best[v['code']] = v
    ranked = sorted(best.values(), key=lambda x: x['worst'])
    for i, v in enumerate(ranked):
        v['rank'] = i + 1

    print(f'  Valid ranked stocks (both PE>0 and PB>0): {len(ranked)}')

    # Print top 20
    print('\n' + '=' * 100)
    print(f'{"Rank":>5} {"Code":<8} {"Name":<10} {"Worst":>7} {"hanPE":>7} {"hanPB":>7} {"PE":>8} {"PB":>7} {"Price":>7} {"Turnover%":>9}  {"Industry"}')
    print('-' * 100)
    for v in ranked[:20]:
        band = ' *' if v['rank'] <= 8 else ''
        print(f'{v["rank"]:>4}{band} {v["code"]:<8} {v["name"]:<10} {v["worst"]:>7.3f} {v["hanpe"]:>7.3f} {v["hanpb"]:>7.3f} {v["pe"]:>8.1f} {v["pb"]:>7.2f} {v["price"]:>7.2f} {v["turnover"]:>9.2f}  {v["industry"]}')

    # Count in bands
    below_thresh = [v for v in ranked if v['worst'] < 0.3]
    print(f'\n  Stocks with worst < 0.3: {len(below_thresh)}')
    print(f'  Rotation band (rank 1-8): top-8 worst range = [{ranked[0]["worst"]:.3f}, {ranked[7]["worst"]:.3f}]' if len(ranked) >= 8 else '')


if __name__ == '__main__':
    main()
