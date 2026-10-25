import re,sys,collections
def parse(fn):
    ev=[];seen=set()
    for l in open(fn):
        m=re.match(r'(\d+\.\d+) \S+\s+(Out|In)\s+IP (\S+)\.(\d+) > (\S+)\.(\d+): Flags \[([^\]]*)\], (?:seq (\d+)(?::(\d+))?, )?(?:ack (\d+), )?.*length (\d+)',l)
        if not m: continue
        t,d,sa,sp,da,dp,fl,s1,s2,ack,ln=m.groups(); t=float(t); ln=int(ln)
        key=(t,d,sp,dp,fl,s1,ack,ln)
        if key in seen: continue
        seen.add(key)
        cport=sp if d=='Out' else dp
        ev.append((t,cport,'C' if d=='Out' else 'S',fl,ln,int(ack) if ack else None,int(s1) if s1 else None))
    return ev
for tgt in ('dovecot','stalwart'):
    ev=parse(tgt+'.txt'); by=collections.defaultdict(list)
    for e in ev: by[e[1]].append(e)
    print('==',tgt,'sessions',len(by))
    for i,(p,es) in enumerate(sorted(by.items(),key=lambda kv:kv[1][0][0]),1):
        t0=es[0][0]
        data=[(e[0]-t0,e[2],e[4]) for e in es if e[4]>0]
        # reply latency: client data segment followed by next server data segment
        lat=[]
        for j,(t,d,l) in enumerate(data):
            if d=='C':
                nxt=[x for x in data[j+1:] if x[1]=='S']
                if nxt: lat.append((l,round((nxt[0][0]-t)*1e3,2),nxt[0][2]))
        # ack ordering: for each server data segment, did a client pure ACK precede the next server data segment?
        gaps=[]
        sd=[e for e in es if e[2]=='S' and e[4]>0]
        for a,b in zip(sd,sd[1:]):
            acked=any(e[2]=='C' and e[4]==0 and a[0]<e[0]<b[0] for e in es)
            gaps.append((a[4],round((b[0]-a[0])*1e3,2),'ack-between' if acked else 'no-ack'))
        print(f' session {i}: client->next-server-data (clen, ms, slen): {lat}')
        print(f'   server data seg -> next server data seg (len, ms, ack): {gaps}')
