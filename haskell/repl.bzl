"""GHCi support"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@io_tweag_rules_haskell//haskell:private/context.bzl", "haskell_context", "render_env")
load(
    "@io_tweag_rules_haskell//haskell:private/path_utils.bzl",
    "is_shared_library",
    "get_lib_name",
    "ln",
    "target_unique_name",
)
load(
    "@io_tweag_rules_haskell//haskell:private/providers.bzl",
    "HaskellBinaryInfo",
    "HaskellBuildInfo",
    "HaskellLibraryInfo",
    "empty_HaskellCcInfo",
    "get_libs_for_ghc_linker",
    "merge_HaskellCcInfo",
)
load("@io_tweag_rules_haskell//haskell:private/set.bzl", "set")


HaskellReplLoadInfo = provider(
    doc = """Haskell REPL target information.

    Information to a Haskell target to load into the REPL as source.
    """,
    fields = {
        # XXX: Do we need to distinguish boot and source files?
        # "boot_files": "Set of boot files",
        "source_files": "Set of files that contain Haskell modules.",
        "cc_dependencies": "Direct cc library dependencies. See HaskellCcInfo.",
        "compiler_flags": "Flags to pass to the Haskell compiler.",
        "repl_ghci_args": "Arbitrary extra arguments to pass to GHCi. This extends `compiler_flags` and `repl_ghci_args` from the toolchain",
    },
)

HaskellReplDepInfo = provider(
    doc = """Haskell REPL dependency information.

    Information to a Haskell target to load into the REPL as a built package.
    """,
    fields = {
        "package_id": "Workspace unique package identifier.",
        "package_caches": "Set of package cache files.",
    },
)

HaskellReplCollectInfo = provider(
    doc = """Collect Haskell REPL information.

    Holds information to generate a REPL that loads some targets as source
    and some targets as built packages.
    """,
    fields = {
        "load_infos": "Dictionary from labels to HaskellReplLoadInfo.",
        "dep_infos": "Dictionary from labels to HaskellReplDepInfo.",
        "prebuilt_dependencies": "Transitive collection of info of wired-in Haskell dependencies.",
        "transitive_cc_dependencies": "Transitive cc library dependencies. See HaskellCcInfo.",
    },
)

HaskellReplInfo = provider(
    doc = """Haskell REPL information.

    Holds information to generate a REPL that loads a specific set of targets
    from source or as built packages.
    """,
    fields = {
        "source_files": "Set Haskell source files to load.",
        "package_ids": "Set of package ids to load.",
        "package_caches": "Set of package cache files.",
        "prebuilt_dependencies": "Transitive collection of info of wired-in Haskell dependencies.",
        "cc_dependencies": "Direct cc library dependencies. See HaskellCcInfo.",
        "transitive_cc_dependencies": "Transitive cc library dependencies. See HaskellCcInfo.",
        "compiler_flags": "Flags to pass to the Haskell compiler.",
        "repl_ghci_args": "Arbitrary extra arguments to pass to GHCi. This extends `compiler_flags` and `repl_ghci_args` from the toolchain",
    },
)


def _create_HaskellReplCollectInfo(target, ctx):
    load_infos = {}
    dep_infos = {}
    if HaskellBuildInfo in target:
        build_info = target[HaskellBuildInfo]
        prebuilt_dependencies = build_info.prebuilt_dependencies
        transitive_cc_dependencies = build_info.transitive_cc_dependencies
    else:
        prebuilt_dependencies = set.empty()
        transitive_cc_dependencies = empty_HaskellCcInfo()

    if HaskellLibraryInfo in target:
        lib_info = target[HaskellLibraryInfo]
        build_info = target[HaskellBuildInfo]
        load_infos[target.label] = HaskellReplLoadInfo(
            source_files = set.union(
                lib_info.boot_files,
                lib_info.source_files,
            ),
            cc_dependencies = build_info.cc_dependencies,
            compiler_flags = getattr(ctx.rule.attr, "compiler_flags", []),
            repl_ghci_args = getattr(ctx.rule.attr, "repl_ghci_args", []),
        )
        dep_infos[target.label] = HaskellReplDepInfo(
            package_id = lib_info.package_id,
            package_caches = build_info.package_caches,
        )
    elif HaskellBinaryInfo in target:
        bin_info = target[HaskellBinaryInfo]
        build_info = target[HaskellBuildInfo]
        load_infos[target.label] = HaskellReplLoadInfo(
            source_files = bin_info.source_files,
            cc_dependencies = build_info.cc_dependencies,
            compiler_flags = ctx.rule.attr.compiler_flags,
            repl_ghci_args = ctx.rule.attr.repl_ghci_args,
        )

    return HaskellReplCollectInfo(
        load_infos = load_infos,
        dep_infos = dep_infos,
        prebuilt_dependencies = prebuilt_dependencies,
        transitive_cc_dependencies = transitive_cc_dependencies,
    )


def _merge_HaskellReplCollectInfo(*args):
    load_infos = {}
    dep_infos = {}
    prebuilt_dependencies = set.empty()
    transitive_cc_dependencies = empty_HaskellCcInfo()
    for arg in args:
        load_infos.update(arg.load_infos)
        dep_infos.update(arg.dep_infos)
        set.mutable_union(
            prebuilt_dependencies,
            arg.prebuilt_dependencies,
        )
        transitive_cc_dependencies = merge_HaskellCcInfo(
            transitive_cc_dependencies,
            arg.transitive_cc_dependencies,
        )

    return HaskellReplCollectInfo(
        load_infos = load_infos,
        dep_infos = dep_infos,
        prebuilt_dependencies = prebuilt_dependencies,
        transitive_cc_dependencies = transitive_cc_dependencies,
    )


def _parse_pattern(pattern_str):
    # We only load targets in the local workspace anyway. So, it's never
    # necessary to specify a workspace. Therefore, we don't allow it.
    if pattern_str.startswith("@"):
        fail("Invalid haskell_repl pattern. Patterns may not specify a workspace. They only apply to the current workspace")

    # To keep things simple, all patterns have to be absolute.
    if not pattern_str.startswith("//"):
        fail("Invalid haskell_repl pattern. Patterns must start with //.")

    # Separate package and target (if present).
    package_target = pattern_str[2:].split(":", maxsplit=2)
    package_str = package_target[0]
    target_str = None
    if len(package_target) == 2:
        target_str = package_target[1]

    # Parse package pattern.
    package = []
    dotdotdot = False  # ... has to be last component in the pattern.
    for s in package_str.split("/"):
        if dotdotdot:
            fail("Invalid haskell_repl pattern. ... has to appear at the end.")
        if s == "...":
            dotdotdot = True
        package.append(s)

    # Parse target pattern.
    if dotdotdot:
        if target_str != None:
            fail("Invalid haskell_repl pattern. ... has to appear at the end.")
    else:
        if target_str == None:
            if len(package) > 0 and package[-1] != "":
                target_str = package[-1]
            else:
                fail("Invalid haskell_repl pattern. The empty string is not a valid target.")

    return struct(
        package = package,
        target = target_str,
    )


def _match_label(pattern, label):
    # Only local workspace labels can match.
    # Despite the docs saying otherwise, labels don't have a workspace_name
    # attribute. So, we use the workspace_root. If it's empty, the target is in
    # the local workspace. Otherwise, it's an external target.
    if label.workspace_root != "":
        return False

    package = label.package.split("/")
    target = label.name

    # Match package components.
    for i in range(min(len(pattern.package), len(package))):
        if pattern.package[i] == "...":
            return True
        elif pattern.package[i] != package[i]:
            return False

    # If no wild-card or mismatch was encountered, the lengths must match.
    # Otherwise, the label's package is not covered.
    if len(pattern.package) != len(package):
        return False

    # Match target.
    if pattern.target == "all" or pattern.target == "*":
        return True
    else:
        return pattern.target == target


def _load_as_source(include, exclude, lbl):
    for pat in exclude:
        if _match_label(pat, lbl):
            return False

    for pat in include:
        if _match_label(pat, lbl):
            return True

    return False


def _create_HaskellReplInfo(include, exclude, collect_info):
    source_files = set.empty()
    package_ids = set.empty()
    package_caches = set.empty()
    cc_dependencies = empty_HaskellCcInfo()
    compiler_flags = []
    repl_ghci_args = []

    for (lbl, load_info) in collect_info.load_infos.items():
        if not _load_as_source(include, exclude, lbl):
            continue

        set.mutable_union(source_files, load_info.source_files)
        cc_dependencies = merge_HaskellCcInfo(
            cc_dependencies,
            load_info.cc_dependencies,
        )
        compiler_flags += load_info.compiler_flags
        repl_ghci_args += load_info.repl_ghci_args

    for (lbl, dep_info) in collect_info.dep_infos.items():
        if _load_as_source(include, exclude, lbl):
            continue

        set.mutable_insert(package_ids, dep_info.package_id)
        set.mutable_union(package_caches, dep_info.package_caches)

    return HaskellReplInfo(
        source_files = source_files,
        package_ids = package_ids,
        package_caches = package_caches,
        prebuilt_dependencies = collect_info.prebuilt_dependencies,
        cc_dependencies = cc_dependencies,
        transitive_cc_dependencies = collect_info.transitive_cc_dependencies,
        compiler_flags = compiler_flags,
        repl_ghci_args = repl_ghci_args,
    )


def _create_repl(hs, ctx, repl_info, output):
    # The base and directory packages are necessary for the GHCi script we use
    # (loads source files and brings in scope the corresponding modules).
    args = ["-package", "base", "-package", "directory"]

    # Load prebuilt dependencies (-package)
    for dep in set.to_list(repl_info.prebuilt_dependencies):
        args.extend(["-package", dep.package])

    # Load built dependencies (-package-id, -package-db)
    for package_id in set.to_list(repl_info.package_ids):
        args.extend(["-package-id", package_id])
    for package_cache in set.to_list(repl_info.package_caches):
        args.extend(["-package-db", package_cache.dirname])

    # Load C library dependencies
    link_ctx = repl_info.cc_dependencies.dynamic_linking
    libs_to_link = link_ctx.dynamic_libraries_for_runtime.to_list()

    # External shared libraries that we need to make available to the REPL.
    # This only includes dynamic libraries as including static libraries here
    # would cause linking errors as ghci cannot load static libraries.
    # XXX: Verify that static libraries can't be loaded by GHCi.
    seen_libs = set.empty()
    libraries = []
    for lib in libs_to_link:
        lib_name = get_lib_name(lib)
        if is_shared_library(lib) and not set.is_member(seen_libs, lib_name):
            set.mutable_insert(seen_libs, lib_name)
            args += ["-l{0}".format(lib_name)]
            libraries.append(lib_name)

    # Transitive library dependencies to have in runfiles.
    (library_deps, ld_library_deps, ghc_env) = get_libs_for_ghc_linker(
        hs,
        repl_info.transitive_cc_dependencies,
        path_prefix = "$RULES_HASKELL_EXEC_ROOT",
    )
    library_path = [paths.dirname(lib.path) for lib in library_deps]
    ld_library_path = [paths.dirname(lib.path) for lib in ld_library_deps]

    # Load source files
    add_sources = [
        "*" + f.path
        for f in set.to_list(repl_info.source_files)
    ]
    ghci_repl_script = hs.actions.declare_file(
        target_unique_name(hs, "ghci-repl-script"),
    )
    hs.actions.expand_template(
        template = ctx.file._ghci_repl_script,
        output = ghci_repl_script,
        substitutions = {
            "{ADD_SOURCES}": " ".join(add_sources),
        },
    )

    # Extra arguments.
    # `compiler flags` is the default set of arguments for the repl,
    # augmented by `repl_ghci_args`.
    # The ordering is important, first compiler flags (from toolchain
    # and local rule), then from `repl_ghci_args`. This way the more
    # specific arguments are listed last, and then have more priority in
    # GHC.
    # Note that most flags for GHCI do have their negative value, so a
    # negative flag in `repl_ghci_args` can disable a positive flag set
    # in `compiler_flags`, such as `-XNoOverloadedStrings` will disable
    # `-XOverloadedStrings`.
    args += (
        hs.toolchain.compiler_flags +
        repl_info.compiler_flags +
        hs.toolchain.repl_ghci_args +
        repl_info.repl_ghci_args
    )

    ghci_repl_wrapper = hs.actions.declare_file(
        target_unique_name(hs, "ghci-repl-wrapper"),
    )
    hs.actions.expand_template(
        template = ctx.file._ghci_repl_wrapper,
        output = ghci_repl_wrapper,
        is_executable = True,
        substitutions = {
            "{ENV}": render_env(ghc_env + {
                # Export RUNFILES_DIR so that targets that require runfiles
                # can be executed in the REPL.
                "RUNFILES_DIR": paths.join("$RULES_HASKELL_EXEC_ROOT", output.path + ".runfiles")
            }),
            "{TOOL}": hs.tools.ghci.path,
            "{ARGS}": " ".join(
                [
                    "-ghci-script",
                    paths.join("$RULES_HASKELL_EXEC_ROOT", ghci_repl_script.path),
                ] + [
                   shell.quote(a) for a in args
                ]
            ),
        },
    )

    # XXX We create a symlink here because we need to force
    # hs.tools.ghci and ghci_repl_script and the best way to do that is
    # to use hs.actions.run. That action, in turn must produce
    # a result, so using ln seems to be the only sane choice.
    extra_inputs = depset(transitive = [
        depset([
            hs.tools.ghci,
            ghci_repl_script,
            ghci_repl_wrapper,
        #    ghc_info_file,
        ]),
        set.to_depset(repl_info.package_caches),
        depset(library_deps),
        depset(ld_library_deps),
        set.to_depset(repl_info.source_files),
    ])
    ln(hs, ghci_repl_wrapper, output, extra_inputs)
    return [DefaultInfo(
        executable = output,
        runfiles = ctx.runfiles(
            transitive_files = extra_inputs,
            collect_data = True,
        ),
    )]


def _haskell_repl_aspect_impl(target, ctx):
    is_eligible = (
        HaskellLibraryInfo in target or
        HaskellBinaryInfo in target
    )
    if not is_eligible:
        return []

    target_info = _create_HaskellReplCollectInfo(target, ctx)
    deps_infos = [
        dep[HaskellReplCollectInfo]
        for dep in ctx.rule.attr.deps
        if HaskellReplCollectInfo in dep
    ]
    collect_info = _merge_HaskellReplCollectInfo(*([target_info] + deps_infos))

    return [collect_info]

haskell_repl_aspect = aspect(
    implementation = _haskell_repl_aspect_impl,
    attr_aspects = ["deps"],
)


def _haskell_repl_impl(ctx):
    collect_info = _merge_HaskellReplCollectInfo(*[
        dep[HaskellReplCollectInfo]
        for dep in ctx.attr.deps
        if HaskellReplCollectInfo in dep
    ])
    include = [_parse_pattern(pat) for pat in ctx.attr.include]
    exclude = [_parse_pattern(pat) for pat in ctx.attr.exclude]
    repl_info = _create_HaskellReplInfo(include, exclude, collect_info)
    hs = haskell_context(ctx)
    return _create_repl(hs, ctx, repl_info, ctx.outputs.repl)


haskell_repl = rule(
    implementation = _haskell_repl_impl,
    attrs = {
        "_ghci_repl_script": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:assets/ghci_script"),
        ),
        "_ghci_repl_wrapper": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:private/ghci_repl_wrapper.sh"),
        ),
        "deps": attr.label_list(
            aspects = [haskell_repl_aspect],
            doc = "List of Haskell targets to load into the REPL",
        ),
        "include": attr.string_list(
            doc = """White-list of targets to load by source.

            Wild-card targets such as //... or //:all are allowed.

            The black-list takes precedence over the white-list.
            """,
            default = ["//..."],
        ),
        "exclude": attr.string_list(
            doc = """Black-list of targets to not load by source but as packages.

            Wild-card targets such as //... or //:all are allowed.

            The black-list takes precedence over the white-list.
            """,
            default = [],
        ),
    },
    executable = True,
    outputs = {
        "repl": "%{name}@repl",
    },
    toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
)