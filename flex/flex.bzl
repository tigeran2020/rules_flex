# Copyright 2018 the rules_flex authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

load(
    "@rules_flex//flex/internal:repository.bzl",
    _flex_repository = "flex_repository",
)
load(
    "@rules_flex//flex/internal:toolchain.bzl",
    _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE",
    _ToolchainInfo = "ToolchainInfo",
)
load(
    "@rules_flex//flex/internal:versions.bzl",
    _DEFAULT_VERSION = "DEFAULT_VERSION",
    _check_version = "check_version",
)
load(
    "@rules_m4//m4:m4.bzl",
    _m4_common = "m4_common",
)

flex_repository = _flex_repository

def _ctx_toolchain(ctx):
    return ctx.toolchains[_TOOLCHAIN_TYPE].flex_toolchain

flex_common = struct(
    TOOLCHAIN_TYPE = _TOOLCHAIN_TYPE,
    ToolchainInfo = _ToolchainInfo,
    flex_toolchain = _ctx_toolchain,
)

def flex_register_toolchains(version = _DEFAULT_VERSION):
    _check_version(version)
    repo_name = "flex_v{}".format(version)
    if repo_name not in native.existing_rules().keys():
        flex_repository(
            name = repo_name,
            version = version,
        )
    native.register_toolchains("@rules_flex//flex/toolchains:v{}".format(version))

_COMMON_ATTR = {
    "src": attr.label(
        mandatory = True,
        allow_single_file = [".l", ".ll", ".l++", ".lxx", ".lpp"],
    ),
    "flex_options": attr.string_list(),
    "_m4_deny_shell": attr.label(
        executable = True,
        cfg = "host",
        default = "@rules_flex//flex/internal:m4_deny_shell",
    ),
}

def _flex_attrs(rule_attrs):
    rule_attrs.update(_COMMON_ATTR)
    return rule_attrs

def _flex_common(ctx):
    m4_toolchain = _m4_common.m4_toolchain(ctx)
    flex_toolchain = flex_common.flex_toolchain(ctx)

    args = ctx.actions.args()
    outputs = []
    header = None

    if ctx.file.src.extension == "l":
        src_ext = "c"

        # The Flex manual documents that `--header-file` and `--c++` are incompatible.
        header = ctx.actions.declare_file("{}.h".format(ctx.attr.name))
        args.add("--header-file=" + header.path)
        outputs.append(header)
    else:
        src_ext = "cc"
        args.add("--c++")

    source = ctx.actions.declare_file("{}.{}".format(ctx.attr.name, src_ext))
    args.add("--outfile=" + source.path)
    outputs.append(source)

    args.add_all(ctx.attr.flex_options)
    args.add_all(ctx.files.src)

    ctx.actions.run(
        executable = flex_toolchain.flex_executable,
        arguments = [args],
        inputs = depset(
            direct = ctx.files.src,
            transitive = [
                flex_toolchain.files,
                m4_toolchain.files,
            ],
        ),
        outputs = outputs,
        tools = [
            ctx.executable._m4_deny_shell,
        ],
        env = {
            "M4": m4_toolchain.m4_executable.path,
            "M4_SYSCMD_SHELL": ctx.executable._m4_deny_shell.path,
        },
        mnemonic = "Flex",
        progress_message = "Flex {}".format(ctx.label),
    )

    return struct(
        source = source,
        header = header,
        outs = depset(direct = outputs),
    )

def _flex(ctx):
    result = _flex_common(ctx)
    return DefaultInfo(files = result.outs)

flex = rule(
    _flex,
    attrs = _COMMON_ATTR,
    toolchains = [
        _m4_common.TOOLCHAIN_TYPE,
        flex_common.TOOLCHAIN_TYPE,
    ],
)

def _cc_library(ctx, flex_result, flex_lexer_h):
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]

    cc_deps = cc_common.merge_cc_infos(cc_infos = [
        dep[CcInfo]
        for dep in ctx.attr.deps
    ])

    cc_public_hdrs = []
    cc_private_hdrs = []
    cc_system_includes = []
    if flex_result.header:
        cc_public_hdrs.append(flex_result.header)
    else:
        cc_private_hdrs.append(flex_lexer_h)
        cc_system_includes.append(flex_lexer_h.dirname)

    cc_feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.attr.features,
    )

    (cc_compilation_context, cc_compilation_outputs) = cc_common.compile(
        name = ctx.attr.name,
        actions = ctx.actions,
        cc_toolchain = cc_toolchain,
        feature_configuration = cc_feature_configuration,
        srcs = [flex_result.source],
        public_hdrs = cc_public_hdrs,
        private_hdrs = cc_private_hdrs,
        system_includes = cc_system_includes,
        compilation_contexts = [cc_deps.compilation_context],
    )

    (cc_linking_context, cc_linking_outputs) = cc_common.create_linking_context_from_compilation_outputs(
        name = ctx.attr.name,
        actions = ctx.actions,
        feature_configuration = cc_feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = cc_compilation_outputs,
        linking_contexts = [cc_deps.linking_context],
    )

    outs = []
    if cc_linking_outputs.library_to_link.static_library:
        outs.append(cc_linking_outputs.library_to_link.static_library)
    if cc_linking_outputs.library_to_link.dynamic_library:
        outs.append(cc_linking_outputs.library_to_link.dynamic_library)

    return struct(
        outs = depset(direct = outs),
        cc_info = CcInfo(
            compilation_context = cc_compilation_context,
            linking_context = cc_linking_context,
        ),
    )

def _flex_cc_library(ctx):
    flex_toolchain = flex_common.flex_toolchain(ctx)
    result = _flex_common(ctx)
    cc_lib = _cc_library(ctx, result, flex_toolchain.flex_lexer_h)
    return [
        DefaultInfo(files = cc_lib.outs),
        cc_lib.cc_info,
    ]

flex_cc_library = rule(
    _flex_cc_library,
    attrs = _flex_attrs({
        "deps": attr.label_list(
            providers = [CcInfo],
        ),
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
        ),
    }),
    provides = [
        CcInfo,
        DefaultInfo,
    ],
    toolchains = [
        _m4_common.TOOLCHAIN_TYPE,
        flex_common.TOOLCHAIN_TYPE,
    ],
    fragments = ["cpp"],
)
