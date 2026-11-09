#!/usr/bin/env python3
import importlib.util,unittest
from pathlib import Path
H=Path(__file__).absolute().parent
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
T=load('retained_frozen_numeric_contracts',H.parent/'test-final-numeric-audit-v1.py')
T.A=load('new_explicit_continuation_numeric_core',H/'audit-final-numeric-gates.py')
unittest.main(module=T)
