from pathlib import Path
import re,subprocess,tempfile
r=Path(__file__).resolve().parent
text=(r/'sca_core.v').read_text()
for name in ('sca_group','sca_extractor','sca_mix'):
    pattern=re.compile(r'(\bmodule '+name+r'\b.*?^\s*\);).*?^endmodule',re.M|re.S)
    text,count=pattern.subn(lambda m:m.group(1)+'\nendmodule',text)
    assert count==1,name
with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp);f=d/'controller.v';f.write_text(text)
    a=d/'bench'
    subprocess.run(['iverilog','-g2012','-s','tb_schedule','-o',a,f,r/'tb_schedule.sv'],check=True)
    subprocess.run(['vvp',a],check=True)
