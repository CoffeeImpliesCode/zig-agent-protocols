# Third-party notices

The source-derived transcriptions are under `research/normative/`. `PROTOCOLS.md` selects literal wire values for implemented MCP, A2A, and ACP behavior; those selections retain the same third-party terms and notices shown below.

## Components and provenance

| Component | Repository path(s) | License | Copyright holder / retained notice | Upstream URL |
| --- | --- | --- | --- | --- |
| A2A 1.0.0, including signed Agent Card text | `research/normative/a2a-1.0.0.md`; `research/normative/instructions-observability.md`; `PROTOCOLS.md` (selected literals) | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [A2A specification](https://a2a-protocol.org/latest/specification/); [LICENSE](https://raw.githubusercontent.com/a2aproject/A2A/v1.0.0/LICENSE) |
| Agent Client Protocol v1/v2 | `research/normative/acp-v1-v2.md`; `PROTOCOLS.md` (selected literals) | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [ACP project](https://agentclientprotocol.com/); [LICENSE](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/LICENSE) |
| MCP 2026-07-28 core and schema | `research/normative/mcp-2026-07-28.md`; `research/normative/mcp-2026-07-28-schema.md`; `PROTOCOLS.md` (selected literals) | Apache-2.0 for the audited specification material; see MCP transition policy below. | No single holder is named in the upstream LICENSE; legacy MIT contributions retain their original terms. | [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28); [LICENSE and transition policy](https://raw.githubusercontent.com/modelcontextprotocol/specification/main/LICENSE) |
| MCP Tasks extension | `research/normative/mcp-2026-07-28.md`; `PROTOCOLS.md` (selected literals) | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [MCP Tasks](https://github.com/modelcontextprotocol/ext-tasks); [LICENSE](https://raw.githubusercontent.com/modelcontextprotocol/ext-tasks/main/LICENSE) |
| MCP Apps extension | `research/normative/ui-protocols.md` | Apache-2.0 for the specification material; see MCP transition policy below. | No single holder is named in the upstream LICENSE; legacy MIT contributions retain their original terms. | [MCP Apps](https://github.com/modelcontextprotocol/ext-apps); [LICENSE and transition policy](https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/LICENSE) |
| MCP Skills extension | `research/normative/instructions-observability.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [MCP Skills](https://github.com/modelcontextprotocol/ext-skills); [LICENSE](https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/LICENSE) |
| A2UI | `research/normative/ui-protocols.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [A2UI specification](https://a2ui.org/specification/v1.0-a2ui/); [LICENSE](https://raw.githubusercontent.com/a2ui-project/a2ui/main/LICENSE) |
| Universal Commerce Protocol (UCP) | `research/normative/commerce.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [UCP release specification](https://ucp.dev/2026-08-25/); [LICENSE](https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/LICENSE) |
| Agentic Commerce Protocol | `research/normative/commerce.md` | Apache-2.0 | `Copyright 2025 OpenAI`; `Copyright 2025 Stripe`. | [Agentic Commerce Protocol](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol); [LICENSE](https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/LICENSE) |
| AP2 | `research/normative/commerce.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [AP2](https://github.com/google-agentic-commerce/AP2); [LICENSE](https://raw.githubusercontent.com/google-agentic-commerce/AP2/main/LICENSE) |
| x402 | `research/normative/commerce.md` | Apache-2.0 | `Copyright 2026 x402 Foundation`. | [x402](https://github.com/x402-foundation/x402); [LICENSE](https://raw.githubusercontent.com/x402-foundation/x402/main/LICENSE) |
| Agent Skills | `research/normative/instructions-observability.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [Agent Skills specification](https://agentskills.io/specification); [LICENSE](https://raw.githubusercontent.com/agentskills/agentskills/main/LICENSE) |
| OpenTelemetry GenAI semantic conventions | `research/normative/instructions-observability.md` | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai); [LICENSE](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/LICENSE) |
| Google `google/rpc/code.proto` error-code values | `research/normative/a2a-1.0.0.md`; `PROTOCOLS.md` (selected literals) | Apache-2.0 | No holder is named in the upstream LICENSE; applicable contributor notices remain in force. | [`google/rpc/code.proto`](https://raw.githubusercontent.com/googleapis/googleapis/master/google/rpc/code.proto); [LICENSE](https://raw.githubusercontent.com/googleapis/googleapis/master/LICENSE) |
| AG-UI 1.0 | `research/normative/ui-protocols.md` | MIT | `Copyright (c) 2025`. | [AG-UI schema](https://ag-ui.com/spec/1.0/schema.json); [LICENSE](https://raw.githubusercontent.com/ag-ui-protocol/ag-ui/main/LICENSE) |
| AGENTS.md | `research/normative/instructions-observability.md` | MIT | `Copyright (c) 2025 OpenAI`. | [AGENTS.md project](https://agents.md/); [LICENSE](https://raw.githubusercontent.com/agentsmd/agents.md/main/LICENSE) |
| Web Bot Auth Internet-Draft `draft-ietf-webbotauth-httpsig-protocol-00` | `research/normative/instructions-observability.md` | IETF Trust Legal Provisions (not MIT or Apache-2.0); see the IETF notice below. | `Copyright (c) 2026 IETF Trust and the persons identified as the document authors. All rights reserved.` | [Internet-Draft](https://www.ietf.org/archive/id/draft-ietf-webbotauth-httpsig-protocol-00.txt); [Trust Legal Provisions](https://trustee.ietf.org/documents/trust-legal-provisions/tlp-5/) |

The copyright-holder field reports the upstream notices identified by the license audit. Where an upstream Apache-2.0 LICENSE names no holder, this notice does not infer one; the copyright of each contribution remains with its applicable holder.

### MCP licensing transition

The MCP project states that all new code and specification contributions are Apache-2.0, while documentation contributions other than specifications are CC-BY-4.0. Contributions originally licensed under MIT and not explicitly relicensed remain MIT; no rights beyond the applicable original license are conveyed for those contributions. The audited 2026-07-28 core/schema and named extensions above are treated under Apache-2.0. This notice does not relicense any contribution that remains under its original MIT terms.

### IETF Web Bot Auth notice

The source is the Internet-Draft by Thibault Meunier and Sandor Major, dated 1 September 2026. Its required source notices state:

> This Internet-Draft is submitted in full conformance with the provisions of BCP 78 and BCP 79.
>
> Copyright (c) 2026 IETF Trust and the persons identified as the document authors. All rights reserved.
>
> This document is subject to BCP 78 and the IETF Trust's Legal Provisions Relating to IETF Documents (https://trustee.ietf.org/license-info) in effect on the date of publication of this document. Please review these documents carefully, as they describe your rights and restrictions with respect to this document. Code Components extracted from this document must include Revised BSD License text as described in Section 4.e of the Trust Legal Provisions and are provided without warranty as described in the Revised BSD License.

The cited draft material is protocol terminology and wire-value transcription, not extracted source-code components. The root MIT grant does not replace the IETF terms. The IETF Trust Legal Provisions require attribution to the IETF and identification of the source document for copied portions; the source and authors are identified above.

## Third-party license texts

### Apache License, Version 2.0

The following Apache-2.0 license text applies to the Apache-2.0 components listed above. MCP's transition-policy statement is reproduced separately above.

Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work of authorship, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!) The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a file
      or class name and description of purpose be included on the same
      "printed page" as the copyright notice for easier identification
      within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

### MIT License for AG-UI 1.0

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### MIT License for AGENTS.md

MIT License

Copyright (c) 2025 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
