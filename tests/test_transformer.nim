
import unittest, strutils, tables, re
import mi_transformer, symbol_map

suite "MI Transformer Tests":
  setup:
    let sm = newSymbolMap()
  
  test "Demangle Global":
    let mangled = "mainVal__hello_u6"
    check sm.demangle(mangled) == "mainVal"
    sm.addGlobal(mangled)
    check sm.getMangled("mainVal") == mangled

  test "Demangle Local":
    let mangled = "localVal_1"
    check sm.demangle(mangled) == "localVal"
    
  test "Output Transformation":
    let line = """^done,locals=[{name="localVal_1",type="NI",value="<optimized out>"},{name="result",type="NI"}]"""
    let expected = """^done,locals=[{name="localVal",type="NI",value="<optimized out>"},{name="result",type="NI"}]"""
    
    let output = transformOutput(line, sm)
    echo "Transformed: ", output
    check output == expected
    
    # Side effect check
    check sm.getMangled("localVal") == "localVal_1"

  test "Input Transformation":
    sm.addLocal("localVal_1")
    let line = "-data-evaluate-expression \"localVal\""
    let expected = "-data-evaluate-expression \"localVal_1\""
    
    let output = transformInput(line, sm)
    echo "Input Transformed: ", output
    check output == expected

  test "Input Transformation var-create":
    sm.addLocal("localVal_1")
    let line = "-var-create - * \"localVal\""
    let expected = "-var-create - * \"localVal_1\""
    
    let output = transformInput(line, sm)
    echo "Input Transformed: ", output
    check output == expected
