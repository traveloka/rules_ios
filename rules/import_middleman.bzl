load("@build_bazel_rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")

_FindImportsAspectInfo = provider(fields = {
    "imported_library_file": "",
    "static_framework_file": "",
    "dynamic_framework_file": "",
    "import_infos": "",
})

def _update_framework(ctx, framework):
    # Updates the `framework` for Apple Silicon
    out_file = ctx.actions.declare_file(ctx.attr.name + "/" + framework.basename + ".framework" + "/" + framework.basename)
    out_dir = ctx.actions.declare_file(ctx.attr.name + "/" + framework.basename + ".framework")
    cmd = """
     set -e
     TOOL="{}"
     FRAMEWORK_BINARY="{}"
     OUT_DIR="{}"
     FW_DIR="$(dirname "$FRAMEWORK_BINARY")"

     # Duplicate the _entire_ input framework
     mkdir -p "$(dirname "$OUT_DIR")"

     ditto "$FW_DIR" "$OUT_DIR"
     "$TOOL" "$OUT_DIR/$(basename "$FRAMEWORK_BINARY")"
   """.format(ctx.files.update_in_place[0].path, framework.path, out_dir.path)
    ctx.actions.run_shell(outputs = [out_dir, out_file], inputs = depset([framework] + ctx.attr.update_in_place[DefaultInfo].default_runfiles.files.to_list()), command = cmd)
    return out_file

def _update_lib(ctx, imported_library):
    # Updates the `imported_library` for Apple Silicon
    out_file = ctx.actions.declare_file(ctx.attr.name + "/" + imported_library.basename)
    cmd = """
     set -e

     TOOL="external/build_bazel_rules_ios/tools/m1_utils/{}.sh"
     BINARY="{}"
     OUT="{}"

     # Duplicate the _entire_ input framework
     mkdir -p "$(dirname "$BINARY")"

     ditto "$BINARY" "$OUT"
     "$TOOL" "$OUT"
   """.format(ctx.executable.update_in_place.basename, imported_library.path, out_file.path)

    ctx.actions.run_shell(outputs = [out_file], inputs = depset([imported_library]), command = cmd)
    return out_file

def _add_to_dict_if_present(dict, key, value):
    if value:
        dict[key] = value

def _make_imports(transitive_sets):
    provider_fields = {}
    if transitive_sets:
        provider_fields["framework_imports"] = depset(transitive = transitive_sets)
    provider_fields["build_archs"] = depset(["arm64"])
    provider_fields["debug_info_binaries"] = depset(transitive_sets)

    # TODO: consider passing along the dsyms
    provider_fields["dsym_imports"] = depset()
    return AppleFrameworkImportInfo(**provider_fields)

def _find_imports_impl(target, ctx):
    static_framework_file = []
    imported_library_file = []
    dynamic_framework_file = []
    import_infos = {}

    deps_to_search = []
    if hasattr(ctx.rule.attr, "deps"):
        deps_to_search = ctx.rule.attr.deps
    if hasattr(ctx.rule.attr, "transitive_deps"):
        deps_to_search = deps_to_search + ctx.rule.attr.transitive_deps

    for dep in deps_to_search:
        if _FindImportsAspectInfo in dep:
            static_framework_file.append(dep[_FindImportsAspectInfo].static_framework_file)
            imported_library_file.append(dep[_FindImportsAspectInfo].imported_library_file)
            dynamic_framework_file.append(dep[_FindImportsAspectInfo].dynamic_framework_file)
            import_infos.update(dep[_FindImportsAspectInfo].import_infos)

    if ctx.rule.kind == "objc_import":
        imported_library_file.append(target[apple_common.Objc].imported_library)
    elif AppleFrameworkImportInfo in target:
        static_framework_file.append(target[apple_common.Objc].static_framework_file)

        target_dynamic_framework_file = target[apple_common.Objc].dynamic_framework_file
        target_dynamic_framework_file_list = target_dynamic_framework_file.to_list()
        if len(target_dynamic_framework_file_list) > 0:
            import_infos[target_dynamic_framework_file_list[0].path] = target[AppleFrameworkImportInfo]

        dynamic_framework_file.append(target_dynamic_framework_file)

    return [_FindImportsAspectInfo(
        dynamic_framework_file = depset(transitive = dynamic_framework_file),
        imported_library_file = depset(transitive = imported_library_file),
        static_framework_file = depset(transitive = static_framework_file),
        import_infos = import_infos,
    )]

find_imports = aspect(
    implementation = _find_imports_impl,
    attr_aspects = ["transitve_deps", "deps"],
    doc = """
Internal aspect for the `import_middleman` see below for a description.
""",
)

# Returns an updated array inputs with new_inputs if they exist
def _replace_inputs(ctx, inputs, new_inputs, update_fn):
    replaced = []
    updated_inputs = {}
    for f in new_inputs:
        out = update_fn(ctx, f)
        updated_inputs[f] = out
        replaced.append(out)

    for f in inputs.to_list():
        if not updated_inputs.get(f, False):
            replaced.append(f)
    return struct(inputs = replaced, replaced = updated_inputs)

def _merge_linked_inputs(deps):
    all_static_framework_file = [depset()]
    all_imported_library_file = [depset()]
    all_dynamic_framework_file = [depset()]
    all_import_infos = {}
    for dep in deps:
        if _FindImportsAspectInfo in dep:
            all_static_framework_file.append(dep[_FindImportsAspectInfo].static_framework_file)
            all_imported_library_file.append(dep[_FindImportsAspectInfo].imported_library_file)
            all_dynamic_framework_file.append(dep[_FindImportsAspectInfo].dynamic_framework_file)
            all_import_infos.update(dep[_FindImportsAspectInfo].import_infos)

    input_static_frameworks = depset(transitive = all_static_framework_file).to_list()
    input_imported_libraries = depset(transitive = all_imported_library_file).to_list()
    input_dynamic_frameworks = depset(transitive = all_dynamic_framework_file).to_list()

    return (input_static_frameworks, input_imported_libraries, input_dynamic_frameworks)


def _deduplicate_test_deps(test_deps, deps):
    filtered = []
    if len(test_deps) == 0:
       return deps 
    for dep in test_deps:
       if dep in deps and not dep.is_source:
          filtered.append(dep)
       else:
          print("SKIP", dep)
    return filtered

def _file_collector_rule_impl(ctx):
    all_static_framework_file = [depset()]
    all_imported_library_file = [depset()]
    all_dynamic_framework_file = [depset()]
    all_import_infos = {}
    for dep in ctx.attr.deps:
        if _FindImportsAspectInfo in dep:
            all_static_framework_file.append(dep[_FindImportsAspectInfo].static_framework_file)
            all_imported_library_file.append(dep[_FindImportsAspectInfo].imported_library_file)
            all_dynamic_framework_file.append(dep[_FindImportsAspectInfo].dynamic_framework_file)
            all_import_infos.update(dep[_FindImportsAspectInfo].import_infos)

    linker_deps = _merge_linked_inputs(ctx.attr.deps)
    test_linker_deps = _merge_linked_inputs(ctx.attr.test_deps)
    input_static_frameworks = _deduplicate_test_deps(test_linker_deps[0], linker_deps[0])
    input_imported_libraries = _deduplicate_test_deps(test_linker_deps[1], linker_deps[1])
    input_dynamic_frameworks = _deduplicate_test_deps(test_linker_deps[2], linker_deps[2])


    objc_provider_fields = {}

    for key in [
        "sdk_dylib",
        "sdk_framework",
        "weak_sdk_framework",
        "imported_library",
        "force_load_library",
        "source",
        "link_inputs",
        "linkopt",
        "library",
        "dynamic_framework_file",
        "static_framework_file",
    ]:
        set = depset(
            direct = [],
            # Note:  we may want to merge this with the below inputs?
            transitive = [getattr(dep[apple_common.Objc], key) for dep in ctx.attr.deps],
        )
        _add_to_dict_if_present(objc_provider_fields, key, set)

    exisiting_imported_libraries = objc_provider_fields.get("imported_library", depset([]))
    # FIXME: do we need to plug this into the outputs?
    replaced_imported_libraries = _replace_inputs(ctx, exisiting_imported_libraries, input_imported_libraries, _update_lib).inputs
    objc_provider_fields["imported_library"] = depset(_deduplicate_test_deps(test_linker_deps[1], replaced_imported_libraries))

    exisiting_static_framework = objc_provider_fields.get("static_framework_file", depset([]))

    deduped_static_framework = depset(_deduplicate_test_deps(test_linker_deps[0], exisiting_static_framework.to_list()))
    print("Deduped", deduped_static_framework, input_static_frameworks)
    print("Deduped2", deduped_static_framework)
    replaced_static_framework = _replace_inputs(ctx, deduped_static_framework, input_static_frameworks, _update_framework)
    objc_provider_fields["static_framework_file"] = depset(replaced_static_framework.inputs)

    # Update dynamic frameworks - note that we need to do some additional
    # processing for the ad-hoc files e.g. ( Info.plist )
    exisiting_dynamic_framework = objc_provider_fields.get("dynamic_framework_file", depset([]))
    deduped_dynamic_framework = depset(_deduplicate_test_deps(test_linker_deps[2], exisiting_dynamic_framework.to_list()))
    dynamic_framework_file = []
    dynamic_framework_dirs = []
    replaced_dyanmic_framework = {}
    for f in input_dynamic_frameworks:
        out = _update_framework(ctx, f)
        replaced_dyanmic_framework[f] = out
        dynamic_framework_file.append(out)
        dynamic_framework_dirs.append(out)

        # Append ad-hoc framework files by name: e.g. ( Info.plist )
        ad_hoc_file = all_import_infos[f.path].framework_imports.to_list()

        # Remove the input framework files from this rule
        ad_hoc_file.remove(f)
        dynamic_framework_dirs.extend(ad_hoc_file)

    for f in deduped_dynamic_framework.to_list():
        if not replaced_dyanmic_framework.get(f, False):
            dynamic_framework_file.append(f)
            dynamic_framework_dirs.append(f)
    objc_provider_fields["dynamic_framework_file"] = depset(dynamic_framework_file)

    replaced_frameworks = replaced_dyanmic_framework.values() + replaced_static_framework.replaced.values()
    if len(replaced_frameworks):
        # Triple quote the new path to put them first. Eliminating other paths
        # may possible but needs more handling of other kinds of frameworks and
        # has edge cases that require baking assumptions to handle.
        objc_provider_fields["linkopt"] = depset(
            ["\"\"\"-F" + "/".join(f.path.split("/")[:-2]) + "\"\"\"" for f in replaced_frameworks],
            transitive = [objc_provider_fields.get("linkopt", depset([]))],
        )


    #print("TestDeps", ctx.attr.test_deps)
    #jfor dep in ctx.attr.test_deps:
    #   print("DEP", dep[apple_common.Objc].library)
    #if len(ctx.attr.test_deps) > 0:
    #    fail(replaced_frameworks)
    objc_provider_fields["link_inputs"] = depset(
        transitive = [
            objc_provider_fields.get("link_inputs", depset([])),
            depset(replaced_frameworks),
        ],
    )

    objc = apple_common.new_objc_provider(
        **objc_provider_fields
    )

    return [
        DefaultInfo(files = depset(dynamic_framework_dirs + replaced_frameworks)),
        objc,
        _make_imports([depset(dynamic_framework_dirs)]),
    ]

import_middleman = rule(
    implementation = _file_collector_rule_impl,
    attrs = {
        "deps": attr.label_list(aspects = [find_imports]),
        "test_deps": attr.label_list(aspects = [find_imports], allow_empty=True),
        "update_in_place": attr.label(executable = True, default = Label("//tools/m1_utils:update_in_place"), cfg = "host"),
    },
    doc = """
This rule adds the ability to update the Mach-o header on imported
libraries and frameworks to get arm64 binaires running on Apple silicon
simulator. For rules_ios, it's added in `app.bzl` and `test.bzl`
    
Why bother doing this? Well some apps have many dependencies which could take
along time on vendors or other parties to update. Because the M1 chip has the
same ISA as ARM64, most binaries will run transparently. Most iOS developers
code is high level enough and isn't specifc to a device or simulator. There are
many caveats and eceptions but getting it running is better than nothing. ( e.g.
`TARGET_OS_SIMULATOR` )
    
This solves the problem at the build system level with the power of bazel. The
idea is pretty straight forward:
1. collect all imported paths
2. update the macho headers with Apples vtool and arm64-to-sim
3. update the linker invocation to use the new libs
    
Now it updates all of the inputs automatically - the action can be taught to do
all of this conditionally if necessary.
    
Note: The action happens in a rule for a few reasons.  This has an interesting
propery: you get a single path for framework lookups at linktime. Perhaps this
can be updated to work without the other behavior
""",
)