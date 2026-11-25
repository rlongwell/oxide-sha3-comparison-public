#!/usr/bin/env python3
"""Validate and chart a completed physical size sweep; never synthesizes samples."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
from statistics import median


def summarize(report,plan):
    if report['state']!='passed':raise ValueError('Only completed physical sweeps can be charted')
    expected={(b['mode'],b['core'],b['trial'],c['length']):c['expected'] for b in plan['batches'] for c in b['cases']}
    actual={}
    for row in report['rows']:
        key=(row['mode'],row['core'],row['trial'],row['length'])
        if key in actual:raise ValueError('Duplicate physical sample')
        if key not in expected or not row['verified'] or row['seconds']<=0:raise ValueError('Unexpected or invalid sample')
        if row['expected']!=expected[key] or row['board']['digest']!=expected[key] or row['board']['accepted']!=row['length']:raise ValueError('Digest/length mismatch')
        if not row['board']['ok']:raise ValueError('Hardware reported a failed sample')
        timer=row['client']['transfer_ns']/1e9 if row['mode']=='ethernet' else row['board']['core_cycles']/1e8
        if row['seconds']!=timer:raise ValueError('Timing summary differs from recorded timer')
        if row['client'] and (row['client']['digest']!=expected[key] or row['client']['length']!=row['length']):raise ValueError('Client result mismatch')
        if row['warmup']!=(row['trial']==0):raise ValueError('Incorrect warmup label')
        actual[key]=row
    if actual.keys()!=expected.keys():raise ValueError('Missing physical samples')
    rows=[]
    modes = [mode for mode in ('replay','ethernet') if any(b['mode']==mode for b in plan['batches'])]
    if not modes:raise ValueError('No supported measurement modes')
    for mode in modes:
        for power in range(6,plan['max_power']+1):
            size=1<<power;entry={'mode':mode,'bytes':size,'samples_per_core':plan['repetitions']}
            samples={core:[actual[(mode,core,t,size)] for t in range(1,plan['repetitions']+1)] for core in ('compact','oxide')}
            for core,values in samples.items():
                seconds=[x['seconds'] for x in values]
                entry.update({core+'_median_seconds':median(seconds),core+'_min_seconds':min(seconds),core+'_max_seconds':max(seconds),
                              core+'_MB_per_second':size/median(seconds)/1e6,core+'_min_MB_per_second':size/max(seconds)/1e6,
                              core+'_max_MB_per_second':size/min(seconds)/1e6})
            ratios=[a['seconds']/b['seconds'] for a,b in zip(samples['oxide'],samples['compact'])]
            entry.update(speedup=entry['oxide_median_seconds']/entry['compact_median_seconds'],
                         paired_min_speedup=min(ratios),paired_max_speedup=max(ratios))
            rows.append(entry)
    return rows


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);args=p.parse_args();root=args.directory
    plan=json.loads((root/'plan.json').read_text());report=json.loads((root/'results.json').read_text())
    assert hashlib.sha256((root/'plan.json').read_bytes()).hexdigest()==report['plan_sha256']
    rows=summarize(report,plan)
    with (root/'summary.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    fields=['mode','core','trial','warmup','length','seconds','MB_per_second','core_cycles','digest','retries','batch','artifact']
    with (root/'samples.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for r in report['rows']:
            row={k:r[k] for k in fields if k in r};row.update(core_cycles=r['board']['core_cycles'],digest=r['expected'],retries=r['client']['retries'] if r['client'] else '')
            w.writerow(row)
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.rcParams.update({'figure.facecolor':'#202124','axes.facecolor':'#27292c','savefig.facecolor':'#202124',
                         'text.color':'#edf0f4','axes.labelcolor':'#edf0f4','xtick.color':'#bdc3ce','ytick.color':'#bdc3ce',
                         'axes.edgecolor':'#60656f','grid.color':'#555b64','font.size':11,'svg.fonttype':'none'})
    colors={'compact':'#6daaff','oxide':'#f0af66'};labels={'compact':'Compact','oxide':'Oxide Quartz'}
    ticks=[2**p for p in (6,10,14,18,22,26,30) if p<=plan['max_power']]
    ticklabels=['64 B','1 KiB','16 KiB','256 KiB','4 MiB','64 MiB','1 GiB'][:len(ticks)]
    fig,axes=plt.subplots(2,2,figsize=(15,9),sharex='col')
    latency,laxes=plt.subplots(1,2,figsize=(15,5))
    for col,mode in enumerate(('replay','ethernet')):
        group=[r for r in rows if r['mode']==mode];sizes=[r['bytes'] for r in group]
        for core in ('compact','oxide'):
            axes[0,col].plot(sizes,[r[core+'_MB_per_second'] for r in group],color=colors[core],marker='o',markersize=3,label=labels[core])
            axes[0,col].fill_between(sizes,[r[core+'_min_MB_per_second'] for r in group],[r[core+'_max_MB_per_second'] for r in group],color=colors[core],alpha=.18)
            laxes[col].plot(sizes,[r[core+'_median_seconds'] for r in group],color=colors[core],marker='o',markersize=3,label=labels[core])
            laxes[col].fill_between(sizes,[r[core+'_min_seconds'] for r in group],[r[core+'_max_seconds'] for r in group],color=colors[core],alpha=.18)
        title='FPGA RAM replay' if mode=='replay' else 'Ethernet → GEM → FPGA'
        axes[0,col].set_title(title,pad=12,fontweight='bold');axes[0,col].set_ylabel('Throughput (MB/s)');axes[0,col].legend(frameon=False)
        axes[0,col].set_ylim(bottom=0)
        axes[1,col].plot(sizes,[r['speedup'] for r in group],color='#c5c9f8',marker='o',markersize=3)
        axes[1,col].fill_between(sizes,[r['paired_min_speedup'] for r in group],[r['paired_max_speedup'] for r in group],color='#c5c9f8',alpha=.18)
        axes[1,col].axhline(1,color='#a2a9b3',linestyle='--',linewidth=1)
        axes[1,col].set_ylabel('Compact speedup (×)');axes[1,col].set_xlabel('Message size (powers of two)')
        laxes[col].set_title(title,pad=12,fontweight='bold');laxes[col].set_ylabel('Time per message (seconds)');laxes[col].set_yscale('log');laxes[col].legend(frameon=False)
        for ax in (axes[0,col],axes[1,col],laxes[col]):
            ax.set_xscale('log',base=2);ax.set_xticks(ticks,ticklabels);ax.grid(True,alpha=.28);ax.spines[['top','right']].set_visible(False)
            # Each panel must remain readable on its own (including video crops).
            ax.tick_params(axis='x',labelsize=9,labelbottom=True)
            ax.set_xlabel('Message size (powers of two)')
    title='SHA3-256 · Compact vs Oxide Quartz'
    subtitle=f'Physical Zybo Z7-20 · 100 MHz · {plan["repetitions"]} timed trials per size and core · identical deterministic data'
    fig.suptitle(title+'\n'+subtitle,fontsize=16,y=.985)
    latency.suptitle(title+' — time per message\n'+subtitle,fontsize=15,y=.99)
    note='Lines: medians. Shading: observed min–max; speedup range pairs matching rounds. Warmups excluded.\nReplay: hardware START→digest, RAM loading excluded. Ethernet: first data send→digest reply, including transport.'
    fig.text(.5,.018,note,ha='center',fontsize=10,color='#bdc3ce');fig.tight_layout(rect=(0,.08,1,1))
    latency.text(.5,.015,'Logarithmic time axis · medians and observed min–max · hardware and transport intervals remain separate',ha='center',fontsize=10,color='#bdc3ce');latency.tight_layout(rect=(0,.07,1,.98))
    for plot,name in ((fig,'throughput-and-speedup'),(latency,'latency')):
        for suffix in ('png','svg'):plot.savefig(root/(name+'.'+suffix),dpi=160)
        plt.close(plot)
    (root/'summary.json').write_text(json.dumps({'kind':'computed-from-physical-samples','source_sha256':hashlib.sha256((root/'results.json').read_bytes()).hexdigest(),'rows':rows},indent=2)+'\n')
    print(root/'throughput-and-speedup.png')


if __name__=='__main__':main()
