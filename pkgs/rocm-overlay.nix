# SPDX-License-Identifier: GPL-2.0-only
#
# ROCm for the BC-250 (gfx1013): build the stack for the ISA-compatible gfx1010
# target, paired at runtime with HSA_OVERRIDE_GFX_VERSION=10.1.0.
_final: prev: {
  rocmPackages = prev.rocmPackages.overrideScope (rocmFinal: rocmPrev: {
    clr = rocmPrev.clr.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          localGpuTargets = ["gfx1010"];
          gpuTargets = ["gfx1010"];
        };
    });
    miopen = rocmPrev.miopen.override {withComposableKernel = false;};
  });

  pythonPackagesExtensions =
    (prev.pythonPackagesExtensions or [])
    ++ [
      (pyFinal: pyPrev: {
        torch = pyPrev.torch.override {gpuTargets = ["gfx1010"];};
        vllm = pyPrev.vllm.overrideAttrs (o: {
          postPatch =
            (o.postPatch or "")
            + ''
              substituteInPlace CMakeLists.txt \
                --replace-fail \
                  'set(HIP_SUPPORTED_ARCHS "gfx906;gfx908;gfx90a;gfx942;gfx950;gfx1030;gfx1100;gfx1101;gfx1200;gfx1201;gfx1150;gfx1151")' \
                  'set(HIP_SUPPORTED_ARCHS "gfx1010")'
            '';
        });
      })
    ];
}
