#!/usr/bin/env luajit
--[[
    test_ffi_image_defect_detector.lua
    Unit, regression, and integration test suite for ffi_image_defect_detector.lua.
]]

local ffi = require("ffi")
local interpreter = arg[-1] or "luajit"

print("=== Running Unit Tests for ffi_image_defect_detector.lua ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --help",
        expect = "Optical Defect Inspector & Image Diff Engine • LuaJIT FFI"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --test",
        expect = "ALL DEFECT DETECTOR TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Synthetic demo mode (--demo --ascii)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --demo --ascii",
        expect = "OPTICAL DEFECT INSPECTOR"
    },
    {
        name = "JSON report export (--demo --json)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --demo --json",
        expect = '"verdict": "FAIL"'
    },
    {
        name = "Pass verdict on identical images",
        cmd = "./LuaJIT/src/luajit -e 'local mod = require(\"ffi_image_defect_detector\"); local g = mod.PCBGenerator.generate_golden_pcb(60, 40); local d = mod.DefectDetector.new(); local res = d:compute_diff(g, g); local b = d:extract_blobs(res); print(\"IDENTICAL_BLOBS_COUNT=\" .. #b)'",
        expect = "IDENTICAL_BLOBS_COUNT=0"
    }
}

local passed = 0
local total_cli = #tests

for i, t in ipairs(tests) do
    local command = t.cmd:gsub("%./LuaJIT/src/luajit", function() return interpreter end)
    local p = assert(io.popen(command .. " 2>&1"))
    local out = p:read("*a")
    local success = p:close()

    if success and out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, total_cli, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, total_cli, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- In-Depth Module Tests
print("\n--- In-Depth FFI Struct & Detection Logic Tests ---")
local mod = require("ffi_image_defect_detector")
local Image = mod.Image
local PCBGenerator = mod.PCBGenerator
local DefectDetector = mod.DefectDetector

local function assert_test(name, cond)
    if cond then
        passed = passed + 1
        print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
    else
        print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
    end
    total_cli = total_cli + 1
end

-- 1. Struct Layout
assert_test("PixelRGB size is 3 bytes", ffi.sizeof("PixelRGB") == 3)
assert_test("DefectBlob size is valid", ffi.sizeof("DefectBlob") > 0)

-- 2. Clean Image Diff produces 0 blobs
local ref = Image.new(50, 50, 100, 150, 200)
local smp = ref:clone()
local det = DefectDetector.new({ tolerance = 20, min_blob_area = 3 })
local res0 = det:compute_diff(ref, smp)
local blobs0 = det:extract_blobs(res0)
assert_test("Zero difference returns 0 blobs", #blobs0 == 0)

-- 3. Synthetic Defect Injections
smp:fill_rect(10, 10, 8, 8, 255, 0, 0) -- square defect of 64 pixels
local res1 = det:compute_diff(ref, smp)
local blobs1 = det:extract_blobs(res1)
assert_test("Single injected defect detected", #blobs1 == 1)
assert_test("Injected defect area is 64 pixels", blobs1[1].area == 64)
assert_test("Injected defect bbox x_min == 10", blobs1[1].x_min == 10)
assert_test("Injected defect bbox y_min == 10", blobs1[1].y_min == 10)

-- Execute the real frame generators for every view and viewport boundary.
local ui = mod.TerminalUI
local state = {golden_img=ref, sample_img=smp, diff_res=res1,
    annotated_img=det:render_annotated_overlay(smp,blobs1), blobs=blobs1,
    min_area=3, elapsed_ms=1.5, status="Saved / special % characters"}
res1.tolerance=30
local function cells(s)
    s=s:gsub("\27%[[0-9;]*m", "")
    local _,n=s:gsub("[^\128-\191]", "")
    return n
end
local bounds_ok=true
for _,dims in ipairs({{2,1},{20,5},{39,12},{60,16},{80,24},{100,30},{180,60}}) do
    for view=1,4 do
        for _,ascii in ipairs({true,false}) do
            state.view,state.use_ascii=view,ascii
            local lines=ui.render_dashboard_frame(state,dims[1],dims[2])
            bounds_ok=bounds_ok and #lines==dims[2]
            for _,line in ipairs(lines) do
                bounds_ok=bounds_ok and cells(line)<=dims[1]-1 and not line:find("[\r\n]")
                if ascii then bounds_ok=bounds_ok and not line:find("\27",1,true) end
            end
        end
    end
end
assert_test("Every view fits small and large viewport boundaries",bounds_ok)
state.use_ascii=true
state.blobs={}
assert_test("Empty defect renderer executes",table.concat(ui.render_dashboard_frame(state,80,24),"\n"):find("No defects detected",1,true)~=nil)
state.blobs={}
for i=1,100 do state.blobs[i]={id=i,severity="CRITICAL",area=64,x_min=1,y_min=2,width=8,height=8,classification=string.rep("long%",40).."\27[2J"} end
state.selected=100
local many=ui.render_dashboard_frame(state,80,24)
assert_test("Large defect list renders selected last item",table.concat(many,"\n"):find(">100",1,true)~=nil)
local original=Image.new(40,20,255,255,255)
local preview=ui.render_preview(original,30,10,true)
assert_test("Proportional preview has centered letterboxing",preview[1]==string.rep(" ",30) and preview[2]:find("@",1,true)~=nil and #preview[2]==30)
local selected_img=ui.selected_overlay(original,{x_min=10,y_min=5,width=8,height=8})
local r,g,b=selected_img:get_pixel(8,3)
local or_,og,ob=original:get_pixel(8,3)
assert_test("Selected overlay uses cyan without mutating source",r==70 and g==225 and b==255 and or_==255 and og==255 and ob==255)
state.blobs=blobs1
state.selected=1
state.view=2
state.use_ascii=false
local colored=table.concat(ui.render_dashboard_frame(state,80,24),"\n")
assert_test("Selected row and severity have color accents",colored:find("\27[48;2;22;43;58m",1,true)~=nil and colored:find("\27[1;31m",1,true)~=nil)
state.use_ascii=true
local framed=ui.render_dashboard_frame(state,80,24)
assert_test("Framed layout has intact corners and selected details",framed[1]:sub(1,1)=="+" and framed[1]:sub(-1)=="+" and framed[24]:sub(-1)=="+" and table.concat(framed,"\n"):find("Selected #1",1,true)~=nil)
local narrow=ui.render_dashboard_frame(state,41,16)
assert_test("Narrow footer retains Quit",table.concat(narrow,"\n"):find("Q Quit",1,true)~=nil)
local crop_ok=true
for _,b in ipairs({{x_min=0,y_min=0,width=1,height=1},
    {x_min=39,y_min=19,width=1,height=1},{x_min=0,y_min=0,width=40,height=20},
    {x_min=10,y_min=5,width=8,height=8}}) do
    local crop=ui.defect_crop(original,b)
    crop_ok=crop_ok and crop.x>=0 and crop.y>=0 and crop.x+crop.width<=40 and crop.y+crop.height<=20
        and crop.x<=b.x_min and crop.y<=b.y_min and crop.x+crop.width>=b.x_min+b.width
        and crop.y+crop.height>=b.y_min+b.height
end
assert_test("Zoom crop includes defect and clamps edge/full-image bounds",crop_ok)
local pixels=Image.new(20,20,0,0,0)
pixels:set_pixel(8,9,12,34,56)
local cropped=ui.crop_view(pixels,{x=7,y=8,width=4,height=4})
local cr,cg,cb=cropped:get_pixel(1,1)
assert_test("Read-only crop uses exact source coordinates",cr==12 and cg==34 and cb==56 and cropped.width==4 and cropped.height==4)
local full=ui.defect_crop(pixels,nil)
assert_test("Empty selection uses full image crop",full.x==0 and full.y==0 and full.width==20 and full.height==20)
state.view=4
local zoom=table.concat(ui.render_dashboard_frame(state,80,24),"\n")
assert_test("Zoom renders matched reference detail and crop coordinates",zoom:find("REFERENCE DETAIL",1,true) and zoom:find("[Defect Zoom]",1,true) and zoom:find("Crop",1,true))
state.blobs={}
assert_test("Zoom without defects renders explicit empty state",table.concat(ui.render_dashboard_frame(state,80,24),"\n"):find("Zoom: no defect selected",1,true)~=nil)
state.blobs=blobs1
local delta=ui.render_changed_rows({"same","new"},{"same","old"})
assert_test("Differential update touches only changed row",delta:find("\27[2;1H",1,true) and not delta:find("\27[1;1H",1,true) and not delta:find("\27[2J",1,true))
local decode=ui.make_key_decoder()
local first=decode("+q \t\27[")
local second=decode("B")
assert_test("Burst and fragmented keys are preserved",table.concat(first,",")=="+,q,SPACE,TAB" and second[1]=="DOWN")
assert_test("Standalone Escape is decoded",decode("\27",true)[1]=="ESC")

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL DEFECT DETECTOR TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
