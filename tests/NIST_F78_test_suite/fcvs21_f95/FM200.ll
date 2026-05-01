; ModuleID = 'col6forge'
source_filename = "tests/NIST_F78_test_suite/fcvs21_f95/FM200.f"
@fmt_fm200_90001 = private unnamed_addr constant [32 x i8] c"                         FM200\0A\00", align 1
@fmt_fm200_90000 = private unnamed_addr constant [43 x i8] c"                     END OF PROGRAM FM200\0A\00", align 1
@fmt_fm200_80000 = private unnamed_addr constant [23 x i8] c"     %5d      DELETED\0A\00", align 1
@fmt_fm200_80002 = private unnamed_addr constant [21 x i8] c"     %5d       PASS\0A\00", align 1
@fmt_fm200_80010 = private unnamed_addr constant [46 x i8] c"     %5d       FAIL          %6d         %6d\0A\00", align 1
@fmt_fm200_80012 = private unnamed_addr constant [40 x i8] c"     %5d       FAIL    %12.5E   %12.5E\0A\00", align 1
@fmt_fm200_80018 = private unnamed_addr constant [32 x i8] c"     %5d       FAIL  %14s %14s\0A\00", align 1
@fmt_fm200_90002 = private unnamed_addr constant [3 x i8] c"1\0A\00", align 1
@fmt_fm200_90004 = private unnamed_addr constant [3 x i8] c" \0A\00", align 1
@fmt_fm200_90006 = private unnamed_addr constant [47 x i8] c"           FORTRAN COMPILER VALIDATION SYSTEM\0A\00", align 1
@fmt_fm200_90008 = private unnamed_addr constant [35 x i8] c"                      VERSION 2.1\0A\00", align 1
@fmt_fm200_90010 = private unnamed_addr constant [49 x i8] c"         FOR OFFICIAL USE ONLY - COPYRIGHT 1978\0A\00", align 1
@fmt_fm200_90012 = private unnamed_addr constant [54 x i8] c"      TEST     PASS/FAIL     COMPUTED        CORRECT\0A\00", align 1
@fmt_fm200_90014 = private unnamed_addr constant [54 x i8] c"      ----------------------------------------------\0A\00", align 1
@fmt_fm200_90016 = private unnamed_addr constant [38 x i8] c"                   SUBSET LEVEL TEST\0A\00", align 1
@fmt_fm200_90020 = private unnamed_addr constant [38 x i8] c"                    %5d TESTS FAILED\0A\00", align 1
@fmt_fm200_90022 = private unnamed_addr constant [38 x i8] c"                    %5d TESTS PASSED\0A\00", align 1
@fmt_fm200_90024 = private unnamed_addr constant [39 x i8] c"                    %5d TESTS DELETED\0A\00", align 1
define void @fm200_() {
entry:
  %t0 = alloca i32
  %t1 = alloca i32
  %t2 = alloca i32
  %t3 = alloca i32
  %t4 = alloca i32
  %t5 = alloca i32
  %t6 = alloca i32
  %t7 = alloca i32
  %t8 = alloca i32
  %t9 = alloca i32
  %t10 = alloca i32
  %t11 = alloca i32
  br label %L22
L22:
  store i32 5, ptr %t1
  br label %bb1
bb1:
  store i32 5, ptr %t2
  store i32 6, ptr %t3
  store i32 0, ptr %t4
  store i32 0, ptr %t5
  store i32 0, ptr %t6
  store i32 0, ptr %t7
  %t12 = load i32, ptr %t3
  %t13 = getelementptr [3 x i8], ptr @str0, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t12, ptr %t13, ptr null, ptr null, i32 0, i32 0)
  br label %bb8
bb8:
  %t14 = load i32, ptr %t3
  %t15 = getelementptr [47 x i8], ptr @str1, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t14, ptr %t15, ptr null, ptr null, i32 0, i32 0)
  br label %bb9
bb9:
  %t16 = load i32, ptr %t3
  %t17 = getelementptr [35 x i8], ptr @str2, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t16, ptr %t17, ptr null, ptr null, i32 0, i32 0)
  br label %bb10
bb10:
  %t18 = load i32, ptr %t3
  %t19 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t18, ptr %t19, ptr null, ptr null, i32 0, i32 0)
  br label %bb11
bb11:
  %t20 = load i32, ptr %t3
  %t21 = getelementptr [49 x i8], ptr @str4, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t20, ptr %t21, ptr null, ptr null, i32 0, i32 0)
  br label %bb12
bb12:
  %t22 = load i32, ptr %t3
  %t23 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t22, ptr %t23, ptr null, ptr null, i32 0, i32 0)
  br label %bb13
bb13:
  %t24 = load i32, ptr %t3
  %t25 = getelementptr [38 x i8], ptr @str5, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t24, ptr %t25, ptr null, ptr null, i32 0, i32 0)
  br label %bb14
bb14:
  %t26 = load i32, ptr %t3
  %t27 = getelementptr [32 x i8], ptr @str6, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t26, ptr %t27, ptr null, ptr null, i32 0, i32 0)
  br label %bb15
bb15:
  %t28 = load i32, ptr %t3
  %t29 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t28, ptr %t29, ptr null, ptr null, i32 0, i32 0)
  br label %bb16
bb16:
  %t30 = load i32, ptr %t3
  %t31 = getelementptr [54 x i8], ptr @str7, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t30, ptr %t31, ptr null, ptr null, i32 0, i32 0)
  br label %bb17
bb17:
  %t32 = load i32, ptr %t3
  %t33 = getelementptr [54 x i8], ptr @str8, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t32, ptr %t33, ptr null, ptr null, i32 0, i32 0)
  br label %bb18
bb18:
  %t34 = load i32, ptr %t3
  %t35 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t34, ptr %t35, ptr null, ptr null, i32 0, i32 0)
  br label %bb19
bb19:
  store i32 1, ptr %t8
  %t36 = load i32, ptr %t7
  %t37 = icmp slt i32 %t36, 0
  br i1 %t37, label %L30010, label %arith_if_zero0
arith_if_zero0:
  %t38 = icmp eq i32 %t36, 0
  br i1 %t38, label %L10, label %L30010
L10:
  br label %bb22
bb22:
  store i32 0, ptr %t9
  store i32 1, ptr %t0
  %t39 = load i32, ptr %t0
  store i32 %t39, ptr %t9
  store i32 1, ptr %t10
  br label %L40010
L40010:
  %t40 = load i32, ptr %t9
  %t41 = sub i32 %t40, 1
  %t42 = icmp slt i32 %t41, 0
  br i1 %t42, label %L20010, label %arith_if_zero1
arith_if_zero1:
  %t43 = icmp eq i32 %t41, 0
  br i1 %t43, label %L10010, label %L20010
L30010:
  %t44 = load i32, ptr %t6
  %t45 = add i32 %t44, 1
  store i32 %t45, ptr %t6
  br label %bb28
bb28:
  %t46 = load i32, ptr %t3
  %t47 = load i32, ptr %t8
  %t48 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t49 = alloca i32, i32 1
  %t50 = getelementptr i32, ptr %t49, i32 0
  store i32 %t47, ptr %t50
  %t51 = alloca ptr, i32 1
  %t52 = getelementptr ptr, ptr %t51, i32 0
  store ptr %t50, ptr %t52
  %t53 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t46, ptr %t48, ptr %t51, ptr %t53, i32 1, i32 0)
  br label %bb29
bb29:
  %t54 = load i32, ptr %t7
  %t55 = icmp slt i32 %t54, 0
  br i1 %t55, label %L10010, label %arith_if_zero2
arith_if_zero2:
  %t56 = icmp eq i32 %t54, 0
  br i1 %t56, label %L21, label %L20010
L10010:
  %t57 = load i32, ptr %t4
  %t58 = add i32 %t57, 1
  store i32 %t58, ptr %t4
  br label %bb31
bb31:
  %t59 = load i32, ptr %t3
  %t60 = load i32, ptr %t8
  %t61 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t62 = alloca i32, i32 1
  %t63 = getelementptr i32, ptr %t62, i32 0
  store i32 %t60, ptr %t63
  %t64 = alloca ptr, i32 1
  %t65 = getelementptr ptr, ptr %t64, i32 0
  store ptr %t63, ptr %t65
  %t66 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t59, ptr %t61, ptr %t64, ptr %t66, i32 1, i32 0)
  br label %bb32
bb32:
  br label %L21
L20010:
  %t67 = load i32, ptr %t5
  %t68 = add i32 %t67, 1
  store i32 %t68, ptr %t5
  br label %bb34
bb34:
  %t69 = load i32, ptr %t3
  %t70 = load i32, ptr %t8
  %t71 = load i32, ptr %t9
  %t72 = load i32, ptr %t10
  %t73 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t74 = alloca i32, i32 3
  %t75 = getelementptr i32, ptr %t74, i32 0
  store i32 %t70, ptr %t75
  %t76 = getelementptr i32, ptr %t74, i32 1
  store i32 %t71, ptr %t76
  %t77 = getelementptr i32, ptr %t74, i32 2
  store i32 %t72, ptr %t77
  %t78 = alloca ptr, i32 3
  %t79 = getelementptr ptr, ptr %t78, i32 0
  store ptr %t75, ptr %t79
  %t80 = getelementptr ptr, ptr %t78, i32 1
  store ptr %t76, ptr %t80
  %t81 = getelementptr ptr, ptr %t78, i32 2
  store ptr %t77, ptr %t81
  %t82 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t69, ptr %t73, ptr %t78, ptr %t82, i32 3, i32 0)
  br label %L21
L21:
  br label %bb36
bb36:
  store i32 2, ptr %t8
  %t83 = load i32, ptr %t7
  %t84 = icmp slt i32 %t83, 0
  br i1 %t84, label %L30020, label %arith_if_zero3
arith_if_zero3:
  %t85 = icmp eq i32 %t83, 0
  br i1 %t85, label %L20, label %L30020
L20:
  br label %bb39
bb39:
  store i32 0, ptr %t9
  %t86 = load i32, ptr %t1
  store i32 %t86, ptr %t9
  store i32 5, ptr %t10
  br label %L40020
L40020:
  %t87 = load i32, ptr %t9
  %t88 = sub i32 %t87, 5
  %t89 = icmp slt i32 %t88, 0
  br i1 %t89, label %L20020, label %arith_if_zero4
arith_if_zero4:
  %t90 = icmp eq i32 %t88, 0
  br i1 %t90, label %L10020, label %L20020
L30020:
  %t91 = load i32, ptr %t6
  %t92 = add i32 %t91, 1
  store i32 %t92, ptr %t6
  br label %bb44
bb44:
  %t93 = load i32, ptr %t3
  %t94 = load i32, ptr %t8
  %t95 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t96 = alloca i32, i32 1
  %t97 = getelementptr i32, ptr %t96, i32 0
  store i32 %t94, ptr %t97
  %t98 = alloca ptr, i32 1
  %t99 = getelementptr ptr, ptr %t98, i32 0
  store ptr %t97, ptr %t99
  %t100 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t93, ptr %t95, ptr %t98, ptr %t100, i32 1, i32 0)
  br label %bb45
bb45:
  %t101 = load i32, ptr %t7
  %t102 = icmp slt i32 %t101, 0
  br i1 %t102, label %L10020, label %arith_if_zero5
arith_if_zero5:
  %t103 = icmp eq i32 %t101, 0
  br i1 %t103, label %L31, label %L20020
L10020:
  %t104 = load i32, ptr %t4
  %t105 = add i32 %t104, 1
  store i32 %t105, ptr %t4
  br label %bb47
bb47:
  %t106 = load i32, ptr %t3
  %t107 = load i32, ptr %t8
  %t108 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t109 = alloca i32, i32 1
  %t110 = getelementptr i32, ptr %t109, i32 0
  store i32 %t107, ptr %t110
  %t111 = alloca ptr, i32 1
  %t112 = getelementptr ptr, ptr %t111, i32 0
  store ptr %t110, ptr %t112
  %t113 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t106, ptr %t108, ptr %t111, ptr %t113, i32 1, i32 0)
  br label %bb48
bb48:
  br label %L31
L20020:
  %t114 = load i32, ptr %t5
  %t115 = add i32 %t114, 1
  store i32 %t115, ptr %t5
  br label %bb50
bb50:
  %t116 = load i32, ptr %t3
  %t117 = load i32, ptr %t8
  %t118 = load i32, ptr %t9
  %t119 = load i32, ptr %t10
  %t120 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t121 = alloca i32, i32 3
  %t122 = getelementptr i32, ptr %t121, i32 0
  store i32 %t117, ptr %t122
  %t123 = getelementptr i32, ptr %t121, i32 1
  store i32 %t118, ptr %t123
  %t124 = getelementptr i32, ptr %t121, i32 2
  store i32 %t119, ptr %t124
  %t125 = alloca ptr, i32 3
  %t126 = getelementptr ptr, ptr %t125, i32 0
  store ptr %t122, ptr %t126
  %t127 = getelementptr ptr, ptr %t125, i32 1
  store ptr %t123, ptr %t127
  %t128 = getelementptr ptr, ptr %t125, i32 2
  store ptr %t124, ptr %t128
  %t129 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t116, ptr %t120, ptr %t125, ptr %t129, i32 3, i32 0)
  br label %L31
L31:
  br label %bb52
bb52:
  store i32 3, ptr %t8
  %t130 = load i32, ptr %t7
  %t131 = icmp slt i32 %t130, 0
  br i1 %t131, label %L30030, label %arith_if_zero6
arith_if_zero6:
  %t132 = icmp eq i32 %t130, 0
  br i1 %t132, label %L30, label %L30030
L30:
  br label %bb55
bb55:
  store i32 1, ptr %t9
  store i32 0, ptr %t9
  store i32 0, ptr %t10
  br label %L40030
L40030:
  %t133 = load i32, ptr %t9
  %t134 = icmp slt i32 %t133, 0
  br i1 %t134, label %L20030, label %arith_if_zero7
arith_if_zero7:
  %t135 = icmp eq i32 %t133, 0
  br i1 %t135, label %L10030, label %L20030
L30030:
  %t136 = load i32, ptr %t6
  %t137 = add i32 %t136, 1
  store i32 %t137, ptr %t6
  br label %bb60
bb60:
  %t138 = load i32, ptr %t3
  %t139 = load i32, ptr %t8
  %t140 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t141 = alloca i32, i32 1
  %t142 = getelementptr i32, ptr %t141, i32 0
  store i32 %t139, ptr %t142
  %t143 = alloca ptr, i32 1
  %t144 = getelementptr ptr, ptr %t143, i32 0
  store ptr %t142, ptr %t144
  %t145 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t138, ptr %t140, ptr %t143, ptr %t145, i32 1, i32 0)
  br label %bb61
bb61:
  %t146 = load i32, ptr %t7
  %t147 = icmp slt i32 %t146, 0
  br i1 %t147, label %L10030, label %arith_if_zero8
arith_if_zero8:
  %t148 = icmp eq i32 %t146, 0
  br i1 %t148, label %L41, label %L20030
L10030:
  %t149 = load i32, ptr %t4
  %t150 = add i32 %t149, 1
  store i32 %t150, ptr %t4
  br label %bb63
bb63:
  %t151 = load i32, ptr %t3
  %t152 = load i32, ptr %t8
  %t153 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t154 = alloca i32, i32 1
  %t155 = getelementptr i32, ptr %t154, i32 0
  store i32 %t152, ptr %t155
  %t156 = alloca ptr, i32 1
  %t157 = getelementptr ptr, ptr %t156, i32 0
  store ptr %t155, ptr %t157
  %t158 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t151, ptr %t153, ptr %t156, ptr %t158, i32 1, i32 0)
  br label %bb64
bb64:
  br label %L41
L20030:
  %t159 = load i32, ptr %t5
  %t160 = add i32 %t159, 1
  store i32 %t160, ptr %t5
  br label %bb66
bb66:
  %t161 = load i32, ptr %t3
  %t162 = load i32, ptr %t8
  %t163 = load i32, ptr %t9
  %t164 = load i32, ptr %t10
  %t165 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t166 = alloca i32, i32 3
  %t167 = getelementptr i32, ptr %t166, i32 0
  store i32 %t162, ptr %t167
  %t168 = getelementptr i32, ptr %t166, i32 1
  store i32 %t163, ptr %t168
  %t169 = getelementptr i32, ptr %t166, i32 2
  store i32 %t164, ptr %t169
  %t170 = alloca ptr, i32 3
  %t171 = getelementptr ptr, ptr %t170, i32 0
  store ptr %t167, ptr %t171
  %t172 = getelementptr ptr, ptr %t170, i32 1
  store ptr %t168, ptr %t172
  %t173 = getelementptr ptr, ptr %t170, i32 2
  store ptr %t169, ptr %t173
  %t174 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t161, ptr %t165, ptr %t170, ptr %t174, i32 3, i32 0)
  br label %L41
L41:
  br label %bb68
bb68:
  store i32 4, ptr %t8
  %t175 = load i32, ptr %t7
  %t176 = icmp slt i32 %t175, 0
  br i1 %t176, label %L30040, label %arith_if_zero9
arith_if_zero9:
  %t177 = icmp eq i32 %t175, 0
  br i1 %t177, label %L40, label %L30040
L40:
  br label %bb71
bb71:
  store i32 0, ptr %t9
  store i32 1, ptr %t9
  store i32 2, ptr %t9
  store i32 2, ptr %t10
  br label %L40040
L40040:
  %t178 = load i32, ptr %t9
  %t179 = sub i32 %t178, 2
  %t180 = icmp slt i32 %t179, 0
  br i1 %t180, label %L20040, label %arith_if_zero10
arith_if_zero10:
  %t181 = icmp eq i32 %t179, 0
  br i1 %t181, label %L10040, label %L20040
L30040:
  %t182 = load i32, ptr %t6
  %t183 = add i32 %t182, 1
  store i32 %t183, ptr %t6
  br label %bb77
bb77:
  %t184 = load i32, ptr %t3
  %t185 = load i32, ptr %t8
  %t186 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t187 = alloca i32, i32 1
  %t188 = getelementptr i32, ptr %t187, i32 0
  store i32 %t185, ptr %t188
  %t189 = alloca ptr, i32 1
  %t190 = getelementptr ptr, ptr %t189, i32 0
  store ptr %t188, ptr %t190
  %t191 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t184, ptr %t186, ptr %t189, ptr %t191, i32 1, i32 0)
  br label %bb78
bb78:
  %t192 = load i32, ptr %t7
  %t193 = icmp slt i32 %t192, 0
  br i1 %t193, label %L10040, label %arith_if_zero11
arith_if_zero11:
  %t194 = icmp eq i32 %t192, 0
  br i1 %t194, label %L51, label %L20040
L10040:
  %t195 = load i32, ptr %t4
  %t196 = add i32 %t195, 1
  store i32 %t196, ptr %t4
  br label %bb80
bb80:
  %t197 = load i32, ptr %t3
  %t198 = load i32, ptr %t8
  %t199 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t200 = alloca i32, i32 1
  %t201 = getelementptr i32, ptr %t200, i32 0
  store i32 %t198, ptr %t201
  %t202 = alloca ptr, i32 1
  %t203 = getelementptr ptr, ptr %t202, i32 0
  store ptr %t201, ptr %t203
  %t204 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t197, ptr %t199, ptr %t202, ptr %t204, i32 1, i32 0)
  br label %bb81
bb81:
  br label %L51
L20040:
  %t205 = load i32, ptr %t5
  %t206 = add i32 %t205, 1
  store i32 %t206, ptr %t5
  br label %bb83
bb83:
  %t207 = load i32, ptr %t3
  %t208 = load i32, ptr %t8
  %t209 = load i32, ptr %t9
  %t210 = load i32, ptr %t10
  %t211 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t212 = alloca i32, i32 3
  %t213 = getelementptr i32, ptr %t212, i32 0
  store i32 %t208, ptr %t213
  %t214 = getelementptr i32, ptr %t212, i32 1
  store i32 %t209, ptr %t214
  %t215 = getelementptr i32, ptr %t212, i32 2
  store i32 %t210, ptr %t215
  %t216 = alloca ptr, i32 3
  %t217 = getelementptr ptr, ptr %t216, i32 0
  store ptr %t213, ptr %t217
  %t218 = getelementptr ptr, ptr %t216, i32 1
  store ptr %t214, ptr %t218
  %t219 = getelementptr ptr, ptr %t216, i32 2
  store ptr %t215, ptr %t219
  %t220 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t207, ptr %t211, ptr %t216, ptr %t220, i32 3, i32 0)
  br label %L51
L51:
  br label %bb85
bb85:
  store i32 5, ptr %t8
  %t221 = load i32, ptr %t7
  %t222 = icmp slt i32 %t221, 0
  br i1 %t222, label %L30050, label %arith_if_zero12
arith_if_zero12:
  %t223 = icmp eq i32 %t221, 0
  br i1 %t223, label %L50, label %L30050
L50:
  br label %bb88
bb88:
  store i32 1, ptr %t9
  store i32 0, ptr %t9
  store i32 0, ptr %t10
  br label %L40050
L40050:
  %t224 = load i32, ptr %t9
  %t225 = icmp slt i32 %t224, 0
  br i1 %t225, label %L20050, label %arith_if_zero13
arith_if_zero13:
  %t226 = icmp eq i32 %t224, 0
  br i1 %t226, label %L10050, label %L20050
L30050:
  %t227 = load i32, ptr %t6
  %t228 = add i32 %t227, 1
  store i32 %t228, ptr %t6
  br label %bb93
bb93:
  %t229 = load i32, ptr %t3
  %t230 = load i32, ptr %t8
  %t231 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t232 = alloca i32, i32 1
  %t233 = getelementptr i32, ptr %t232, i32 0
  store i32 %t230, ptr %t233
  %t234 = alloca ptr, i32 1
  %t235 = getelementptr ptr, ptr %t234, i32 0
  store ptr %t233, ptr %t235
  %t236 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t229, ptr %t231, ptr %t234, ptr %t236, i32 1, i32 0)
  br label %bb94
bb94:
  %t237 = load i32, ptr %t7
  %t238 = icmp slt i32 %t237, 0
  br i1 %t238, label %L10050, label %arith_if_zero14
arith_if_zero14:
  %t239 = icmp eq i32 %t237, 0
  br i1 %t239, label %L61, label %L20050
L10050:
  %t240 = load i32, ptr %t4
  %t241 = add i32 %t240, 1
  store i32 %t241, ptr %t4
  br label %bb96
bb96:
  %t242 = load i32, ptr %t3
  %t243 = load i32, ptr %t8
  %t244 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t245 = alloca i32, i32 1
  %t246 = getelementptr i32, ptr %t245, i32 0
  store i32 %t243, ptr %t246
  %t247 = alloca ptr, i32 1
  %t248 = getelementptr ptr, ptr %t247, i32 0
  store ptr %t246, ptr %t248
  %t249 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t242, ptr %t244, ptr %t247, ptr %t249, i32 1, i32 0)
  br label %bb97
bb97:
  br label %L61
L20050:
  %t250 = load i32, ptr %t5
  %t251 = add i32 %t250, 1
  store i32 %t251, ptr %t5
  br label %bb99
bb99:
  %t252 = load i32, ptr %t3
  %t253 = load i32, ptr %t8
  %t254 = load i32, ptr %t9
  %t255 = load i32, ptr %t10
  %t256 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t257 = alloca i32, i32 3
  %t258 = getelementptr i32, ptr %t257, i32 0
  store i32 %t253, ptr %t258
  %t259 = getelementptr i32, ptr %t257, i32 1
  store i32 %t254, ptr %t259
  %t260 = getelementptr i32, ptr %t257, i32 2
  store i32 %t255, ptr %t260
  %t261 = alloca ptr, i32 3
  %t262 = getelementptr ptr, ptr %t261, i32 0
  store ptr %t258, ptr %t262
  %t263 = getelementptr ptr, ptr %t261, i32 1
  store ptr %t259, ptr %t263
  %t264 = getelementptr ptr, ptr %t261, i32 2
  store ptr %t260, ptr %t264
  %t265 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t252, ptr %t256, ptr %t261, ptr %t265, i32 3, i32 0)
  br label %L61
L61:
  br label %bb101
bb101:
  store i32 6, ptr %t8
  %t266 = load i32, ptr %t7
  %t267 = icmp slt i32 %t266, 0
  br i1 %t267, label %L30060, label %arith_if_zero15
arith_if_zero15:
  %t268 = icmp eq i32 %t266, 0
  br i1 %t268, label %L60, label %L30060
L60:
  br label %bb104
bb104:
  store i32 0, ptr %t9
  store i32 3, ptr %t10
  store i32 9, ptr %t9
  store i32 3, ptr %t9
  br label %L40060
L40060:
  %t269 = load i32, ptr %t9
  %t270 = sub i32 %t269, 3
  %t271 = icmp slt i32 %t270, 0
  br i1 %t271, label %L20060, label %arith_if_zero16
arith_if_zero16:
  %t272 = icmp eq i32 %t270, 0
  br i1 %t272, label %L10060, label %L20060
L30060:
  %t273 = load i32, ptr %t6
  %t274 = add i32 %t273, 1
  store i32 %t274, ptr %t6
  br label %bb110
bb110:
  %t275 = load i32, ptr %t3
  %t276 = load i32, ptr %t8
  %t277 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t278 = alloca i32, i32 1
  %t279 = getelementptr i32, ptr %t278, i32 0
  store i32 %t276, ptr %t279
  %t280 = alloca ptr, i32 1
  %t281 = getelementptr ptr, ptr %t280, i32 0
  store ptr %t279, ptr %t281
  %t282 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t275, ptr %t277, ptr %t280, ptr %t282, i32 1, i32 0)
  br label %bb111
bb111:
  %t283 = load i32, ptr %t7
  %t284 = icmp slt i32 %t283, 0
  br i1 %t284, label %L10060, label %arith_if_zero17
arith_if_zero17:
  %t285 = icmp eq i32 %t283, 0
  br i1 %t285, label %L71, label %L20060
L10060:
  %t286 = load i32, ptr %t4
  %t287 = add i32 %t286, 1
  store i32 %t287, ptr %t4
  br label %bb113
bb113:
  %t288 = load i32, ptr %t3
  %t289 = load i32, ptr %t8
  %t290 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t291 = alloca i32, i32 1
  %t292 = getelementptr i32, ptr %t291, i32 0
  store i32 %t289, ptr %t292
  %t293 = alloca ptr, i32 1
  %t294 = getelementptr ptr, ptr %t293, i32 0
  store ptr %t292, ptr %t294
  %t295 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t288, ptr %t290, ptr %t293, ptr %t295, i32 1, i32 0)
  br label %bb114
bb114:
  br label %L71
L20060:
  %t296 = load i32, ptr %t5
  %t297 = add i32 %t296, 1
  store i32 %t297, ptr %t5
  br label %bb116
bb116:
  %t298 = load i32, ptr %t3
  %t299 = load i32, ptr %t8
  %t300 = load i32, ptr %t9
  %t301 = load i32, ptr %t10
  %t302 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t303 = alloca i32, i32 3
  %t304 = getelementptr i32, ptr %t303, i32 0
  store i32 %t299, ptr %t304
  %t305 = getelementptr i32, ptr %t303, i32 1
  store i32 %t300, ptr %t305
  %t306 = getelementptr i32, ptr %t303, i32 2
  store i32 %t301, ptr %t306
  %t307 = alloca ptr, i32 3
  %t308 = getelementptr ptr, ptr %t307, i32 0
  store ptr %t304, ptr %t308
  %t309 = getelementptr ptr, ptr %t307, i32 1
  store ptr %t305, ptr %t309
  %t310 = getelementptr ptr, ptr %t307, i32 2
  store ptr %t306, ptr %t310
  %t311 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t298, ptr %t302, ptr %t307, ptr %t311, i32 3, i32 0)
  br label %L71
L71:
  br label %bb118
bb118:
  store i32 7, ptr %t8
  %t312 = load i32, ptr %t7
  %t313 = icmp slt i32 %t312, 0
  br i1 %t313, label %L30070, label %arith_if_zero18
arith_if_zero18:
  %t314 = icmp eq i32 %t312, 0
  br i1 %t314, label %L70, label %L30070
L70:
  br label %bb121
bb121:
  store i32 0, ptr %t9
  store i32 5, ptr %t11
  store i32 6, ptr %t1
  %t315 = load i32, ptr %t11
  %t316 = load i32, ptr %t1
  %t317 = add i32 %t315, %t316
  store i32 %t317, ptr %t9
  store i32 11, ptr %t10
  br label %L40070
L40070:
  %t318 = load i32, ptr %t9
  %t319 = sub i32 %t318, 11
  %t320 = icmp slt i32 %t319, 0
  br i1 %t320, label %L20070, label %arith_if_zero19
arith_if_zero19:
  %t321 = icmp eq i32 %t319, 0
  br i1 %t321, label %L10070, label %L20070
L30070:
  %t322 = load i32, ptr %t6
  %t323 = add i32 %t322, 1
  store i32 %t323, ptr %t6
  br label %bb128
bb128:
  %t324 = load i32, ptr %t3
  %t325 = load i32, ptr %t8
  %t326 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t327 = alloca i32, i32 1
  %t328 = getelementptr i32, ptr %t327, i32 0
  store i32 %t325, ptr %t328
  %t329 = alloca ptr, i32 1
  %t330 = getelementptr ptr, ptr %t329, i32 0
  store ptr %t328, ptr %t330
  %t331 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t324, ptr %t326, ptr %t329, ptr %t331, i32 1, i32 0)
  br label %bb129
bb129:
  %t332 = load i32, ptr %t7
  %t333 = icmp slt i32 %t332, 0
  br i1 %t333, label %L10070, label %arith_if_zero20
arith_if_zero20:
  %t334 = icmp eq i32 %t332, 0
  br i1 %t334, label %L81, label %L20070
L10070:
  %t335 = load i32, ptr %t4
  %t336 = add i32 %t335, 1
  store i32 %t336, ptr %t4
  br label %bb131
bb131:
  %t337 = load i32, ptr %t3
  %t338 = load i32, ptr %t8
  %t339 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t340 = alloca i32, i32 1
  %t341 = getelementptr i32, ptr %t340, i32 0
  store i32 %t338, ptr %t341
  %t342 = alloca ptr, i32 1
  %t343 = getelementptr ptr, ptr %t342, i32 0
  store ptr %t341, ptr %t343
  %t344 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t337, ptr %t339, ptr %t342, ptr %t344, i32 1, i32 0)
  br label %bb132
bb132:
  br label %L81
L20070:
  %t345 = load i32, ptr %t5
  %t346 = add i32 %t345, 1
  store i32 %t346, ptr %t5
  br label %bb134
bb134:
  %t347 = load i32, ptr %t3
  %t348 = load i32, ptr %t8
  %t349 = load i32, ptr %t9
  %t350 = load i32, ptr %t10
  %t351 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t352 = alloca i32, i32 3
  %t353 = getelementptr i32, ptr %t352, i32 0
  store i32 %t348, ptr %t353
  %t354 = getelementptr i32, ptr %t352, i32 1
  store i32 %t349, ptr %t354
  %t355 = getelementptr i32, ptr %t352, i32 2
  store i32 %t350, ptr %t355
  %t356 = alloca ptr, i32 3
  %t357 = getelementptr ptr, ptr %t356, i32 0
  store ptr %t353, ptr %t357
  %t358 = getelementptr ptr, ptr %t356, i32 1
  store ptr %t354, ptr %t358
  %t359 = getelementptr ptr, ptr %t356, i32 2
  store ptr %t355, ptr %t359
  %t360 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t347, ptr %t351, ptr %t356, ptr %t360, i32 3, i32 0)
  br label %L81
L81:
  br label %bb136
bb136:
  store i32 8, ptr %t8
  %t361 = load i32, ptr %t7
  %t362 = icmp slt i32 %t361, 0
  br i1 %t362, label %L30080, label %arith_if_zero21
arith_if_zero21:
  %t363 = icmp eq i32 %t361, 0
  br i1 %t363, label %L80, label %L30080
L80:
  br label %bb139
bb139:
  store i32 0, ptr %t9
  store i32 5, ptr %t11
  store i32 4, ptr %t1
  %t364 = load i32, ptr %t11
  %t365 = load i32, ptr %t1
  %t366 = add i32 %t364, %t365
  store i32 %t366, ptr %t9
  store i32 9, ptr %t10
  br label %L40080
L40080:
  %t367 = load i32, ptr %t9
  %t368 = sub i32 %t367, 9
  %t369 = icmp slt i32 %t368, 0
  br i1 %t369, label %L20080, label %arith_if_zero22
arith_if_zero22:
  %t370 = icmp eq i32 %t368, 0
  br i1 %t370, label %L10080, label %L20080
L30080:
  %t371 = load i32, ptr %t6
  %t372 = add i32 %t371, 1
  store i32 %t372, ptr %t6
  br label %bb146
bb146:
  %t373 = load i32, ptr %t3
  %t374 = load i32, ptr %t8
  %t375 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t376 = alloca i32, i32 1
  %t377 = getelementptr i32, ptr %t376, i32 0
  store i32 %t374, ptr %t377
  %t378 = alloca ptr, i32 1
  %t379 = getelementptr ptr, ptr %t378, i32 0
  store ptr %t377, ptr %t379
  %t380 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t373, ptr %t375, ptr %t378, ptr %t380, i32 1, i32 0)
  br label %bb147
bb147:
  %t381 = load i32, ptr %t7
  %t382 = icmp slt i32 %t381, 0
  br i1 %t382, label %L10080, label %arith_if_zero23
arith_if_zero23:
  %t383 = icmp eq i32 %t381, 0
  br i1 %t383, label %L91, label %L20080
L10080:
  %t384 = load i32, ptr %t4
  %t385 = add i32 %t384, 1
  store i32 %t385, ptr %t4
  br label %bb149
bb149:
  %t386 = load i32, ptr %t3
  %t387 = load i32, ptr %t8
  %t388 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t389 = alloca i32, i32 1
  %t390 = getelementptr i32, ptr %t389, i32 0
  store i32 %t387, ptr %t390
  %t391 = alloca ptr, i32 1
  %t392 = getelementptr ptr, ptr %t391, i32 0
  store ptr %t390, ptr %t392
  %t393 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t386, ptr %t388, ptr %t391, ptr %t393, i32 1, i32 0)
  br label %bb150
bb150:
  br label %L91
L20080:
  %t394 = load i32, ptr %t5
  %t395 = add i32 %t394, 1
  store i32 %t395, ptr %t5
  br label %bb152
bb152:
  %t396 = load i32, ptr %t3
  %t397 = load i32, ptr %t8
  %t398 = load i32, ptr %t9
  %t399 = load i32, ptr %t10
  %t400 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t401 = alloca i32, i32 3
  %t402 = getelementptr i32, ptr %t401, i32 0
  store i32 %t397, ptr %t402
  %t403 = getelementptr i32, ptr %t401, i32 1
  store i32 %t398, ptr %t403
  %t404 = getelementptr i32, ptr %t401, i32 2
  store i32 %t399, ptr %t404
  %t405 = alloca ptr, i32 3
  %t406 = getelementptr ptr, ptr %t405, i32 0
  store ptr %t402, ptr %t406
  %t407 = getelementptr ptr, ptr %t405, i32 1
  store ptr %t403, ptr %t407
  %t408 = getelementptr ptr, ptr %t405, i32 2
  store ptr %t404, ptr %t408
  %t409 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t396, ptr %t400, ptr %t405, ptr %t409, i32 3, i32 0)
  br label %L91
L91:
  br label %bb154
bb154:
  store i32 9, ptr %t8
  %t410 = load i32, ptr %t7
  %t411 = icmp slt i32 %t410, 0
  br i1 %t411, label %L30090, label %arith_if_zero24
arith_if_zero24:
  %t412 = icmp eq i32 %t410, 0
  br i1 %t412, label %L90, label %L30090
L90:
  br label %bb157
bb157:
  store i32 0, ptr %t11
  store i32 2, ptr %t11
  %t413 = load i32, ptr %t11
  store i32 %t413, ptr %t9
  store i32 2, ptr %t10
  br label %L40090
L40090:
  %t414 = load i32, ptr %t9
  %t415 = sub i32 %t414, 2
  %t416 = icmp slt i32 %t415, 0
  br i1 %t416, label %L20090, label %arith_if_zero25
arith_if_zero25:
  %t417 = icmp eq i32 %t415, 0
  br i1 %t417, label %L10090, label %L20090
L30090:
  %t418 = load i32, ptr %t6
  %t419 = add i32 %t418, 1
  store i32 %t419, ptr %t6
  br label %bb163
bb163:
  %t420 = load i32, ptr %t3
  %t421 = load i32, ptr %t8
  %t422 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t423 = alloca i32, i32 1
  %t424 = getelementptr i32, ptr %t423, i32 0
  store i32 %t421, ptr %t424
  %t425 = alloca ptr, i32 1
  %t426 = getelementptr ptr, ptr %t425, i32 0
  store ptr %t424, ptr %t426
  %t427 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t420, ptr %t422, ptr %t425, ptr %t427, i32 1, i32 0)
  br label %bb164
bb164:
  %t428 = load i32, ptr %t7
  %t429 = icmp slt i32 %t428, 0
  br i1 %t429, label %L10090, label %arith_if_zero26
arith_if_zero26:
  %t430 = icmp eq i32 %t428, 0
  br i1 %t430, label %L101, label %L20090
L10090:
  %t431 = load i32, ptr %t4
  %t432 = add i32 %t431, 1
  store i32 %t432, ptr %t4
  br label %bb166
bb166:
  %t433 = load i32, ptr %t3
  %t434 = load i32, ptr %t8
  %t435 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t436 = alloca i32, i32 1
  %t437 = getelementptr i32, ptr %t436, i32 0
  store i32 %t434, ptr %t437
  %t438 = alloca ptr, i32 1
  %t439 = getelementptr ptr, ptr %t438, i32 0
  store ptr %t437, ptr %t439
  %t440 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t433, ptr %t435, ptr %t438, ptr %t440, i32 1, i32 0)
  br label %bb167
bb167:
  br label %L101
L20090:
  %t441 = load i32, ptr %t5
  %t442 = add i32 %t441, 1
  store i32 %t442, ptr %t5
  br label %bb169
bb169:
  %t443 = load i32, ptr %t3
  %t444 = load i32, ptr %t8
  %t445 = load i32, ptr %t9
  %t446 = load i32, ptr %t10
  %t447 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t448 = alloca i32, i32 3
  %t449 = getelementptr i32, ptr %t448, i32 0
  store i32 %t444, ptr %t449
  %t450 = getelementptr i32, ptr %t448, i32 1
  store i32 %t445, ptr %t450
  %t451 = getelementptr i32, ptr %t448, i32 2
  store i32 %t446, ptr %t451
  %t452 = alloca ptr, i32 3
  %t453 = getelementptr ptr, ptr %t452, i32 0
  store ptr %t449, ptr %t453
  %t454 = getelementptr ptr, ptr %t452, i32 1
  store ptr %t450, ptr %t454
  %t455 = getelementptr ptr, ptr %t452, i32 2
  store ptr %t451, ptr %t455
  %t456 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t443, ptr %t447, ptr %t452, ptr %t456, i32 3, i32 0)
  br label %L101
L101:
  br label %bb171
bb171:
  store i32 10, ptr %t8
  %t457 = load i32, ptr %t7
  %t458 = icmp slt i32 %t457, 0
  br i1 %t458, label %L30100, label %arith_if_zero27
arith_if_zero27:
  %t459 = icmp eq i32 %t457, 0
  br i1 %t459, label %L100, label %L30100
L100:
  br label %bb174
bb174:
  store i32 0, ptr %t11
  %t460 = add i32 1, 1
  %t461 = add i32 %t460, 1
  %t462 = add i32 %t461, 1
  %t463 = add i32 %t462, 1
  %t464 = add i32 %t463, 1
  %t465 = add i32 %t464, 1
  %t466 = add i32 %t465, 1
  %t467 = add i32 %t466, 1
  store i32 %t467, ptr %t11
  %t468 = load i32, ptr %t11
  store i32 %t468, ptr %t9
  store i32 9, ptr %t10
  br label %L40100
L40100:
  %t469 = load i32, ptr %t9
  %t470 = sub i32 %t469, 9
  %t471 = icmp slt i32 %t470, 0
  br i1 %t471, label %L20100, label %arith_if_zero28
arith_if_zero28:
  %t472 = icmp eq i32 %t470, 0
  br i1 %t472, label %L10100, label %L20100
L30100:
  %t473 = load i32, ptr %t6
  %t474 = add i32 %t473, 1
  store i32 %t474, ptr %t6
  br label %bb180
bb180:
  %t475 = load i32, ptr %t3
  %t476 = load i32, ptr %t8
  %t477 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t478 = alloca i32, i32 1
  %t479 = getelementptr i32, ptr %t478, i32 0
  store i32 %t476, ptr %t479
  %t480 = alloca ptr, i32 1
  %t481 = getelementptr ptr, ptr %t480, i32 0
  store ptr %t479, ptr %t481
  %t482 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t475, ptr %t477, ptr %t480, ptr %t482, i32 1, i32 0)
  br label %bb181
bb181:
  %t483 = load i32, ptr %t7
  %t484 = icmp slt i32 %t483, 0
  br i1 %t484, label %L10100, label %arith_if_zero29
arith_if_zero29:
  %t485 = icmp eq i32 %t483, 0
  br i1 %t485, label %L111, label %L20100
L10100:
  %t486 = load i32, ptr %t4
  %t487 = add i32 %t486, 1
  store i32 %t487, ptr %t4
  br label %bb183
bb183:
  %t488 = load i32, ptr %t3
  %t489 = load i32, ptr %t8
  %t490 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t491 = alloca i32, i32 1
  %t492 = getelementptr i32, ptr %t491, i32 0
  store i32 %t489, ptr %t492
  %t493 = alloca ptr, i32 1
  %t494 = getelementptr ptr, ptr %t493, i32 0
  store ptr %t492, ptr %t494
  %t495 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t488, ptr %t490, ptr %t493, ptr %t495, i32 1, i32 0)
  br label %bb184
bb184:
  br label %L111
L20100:
  %t496 = load i32, ptr %t5
  %t497 = add i32 %t496, 1
  store i32 %t497, ptr %t5
  br label %bb186
bb186:
  %t498 = load i32, ptr %t3
  %t499 = load i32, ptr %t8
  %t500 = load i32, ptr %t9
  %t501 = load i32, ptr %t10
  %t502 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t503 = alloca i32, i32 3
  %t504 = getelementptr i32, ptr %t503, i32 0
  store i32 %t499, ptr %t504
  %t505 = getelementptr i32, ptr %t503, i32 1
  store i32 %t500, ptr %t505
  %t506 = getelementptr i32, ptr %t503, i32 2
  store i32 %t501, ptr %t506
  %t507 = alloca ptr, i32 3
  %t508 = getelementptr ptr, ptr %t507, i32 0
  store ptr %t504, ptr %t508
  %t509 = getelementptr ptr, ptr %t507, i32 1
  store ptr %t505, ptr %t509
  %t510 = getelementptr ptr, ptr %t507, i32 2
  store ptr %t506, ptr %t510
  %t511 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t498, ptr %t502, ptr %t507, ptr %t511, i32 3, i32 0)
  br label %L111
L111:
  br label %bb188
bb188:
  store i32 11, ptr %t8
  %t512 = load i32, ptr %t7
  %t513 = icmp slt i32 %t512, 0
  br i1 %t513, label %L30110, label %arith_if_zero30
arith_if_zero30:
  %t514 = icmp eq i32 %t512, 0
  br i1 %t514, label %L110, label %L30110
L110:
  br label %bb191
bb191:
  store i32 1, ptr %t11
  store i32 0, ptr %t9
  %t515 = load i32, ptr %t11
  %t516 = load i32, ptr %t11
  %t517 = add i32 %t515, %t516
  %t518 = load i32, ptr %t11
  %t519 = add i32 %t517, %t518
  %t520 = load i32, ptr %t11
  %t521 = add i32 %t519, %t520
  %t522 = load i32, ptr %t11
  %t523 = add i32 %t521, %t522
  %t524 = load i32, ptr %t11
  %t525 = add i32 %t523, %t524
  %t526 = load i32, ptr %t11
  %t527 = add i32 %t525, %t526
  %t528 = load i32, ptr %t11
  %t529 = add i32 %t527, %t528
  %t530 = load i32, ptr %t11
  %t531 = add i32 %t529, %t530
  %t532 = load i32, ptr %t11
  %t533 = add i32 %t531, %t532
  %t534 = load i32, ptr %t11
  %t535 = add i32 %t533, %t534
  %t536 = load i32, ptr %t11
  %t537 = add i32 %t535, %t536
  %t538 = load i32, ptr %t11
  %t539 = add i32 %t537, %t538
  %t540 = load i32, ptr %t11
  %t541 = add i32 %t539, %t540
  %t542 = load i32, ptr %t11
  %t543 = add i32 %t541, %t542
  %t544 = load i32, ptr %t11
  %t545 = add i32 %t543, %t544
  %t546 = load i32, ptr %t11
  %t547 = add i32 %t545, %t546
  %t548 = load i32, ptr %t11
  %t549 = add i32 %t547, %t548
  %t550 = load i32, ptr %t11
  %t551 = add i32 %t549, %t550
  %t552 = load i32, ptr %t11
  %t553 = add i32 %t551, %t552
  %t554 = load i32, ptr %t11
  %t555 = add i32 %t553, %t554
  %t556 = load i32, ptr %t11
  %t557 = add i32 %t555, %t556
  %t558 = load i32, ptr %t11
  %t559 = add i32 %t557, %t558
  %t560 = load i32, ptr %t11
  %t561 = add i32 %t559, %t560
  %t562 = load i32, ptr %t11
  %t563 = add i32 %t561, %t562
  %t564 = load i32, ptr %t11
  %t565 = add i32 %t563, %t564
  %t566 = load i32, ptr %t11
  %t567 = add i32 %t565, %t566
  %t568 = load i32, ptr %t11
  %t569 = add i32 %t567, %t568
  %t570 = load i32, ptr %t11
  %t571 = add i32 %t569, %t570
  %t572 = load i32, ptr %t11
  %t573 = add i32 %t571, %t572
  %t574 = load i32, ptr %t11
  %t575 = add i32 %t573, %t574
  %t576 = load i32, ptr %t11
  %t577 = add i32 %t575, %t576
  %t578 = load i32, ptr %t11
  %t579 = add i32 %t577, %t578
  %t580 = load i32, ptr %t11
  %t581 = add i32 %t579, %t580
  %t582 = load i32, ptr %t11
  %t583 = add i32 %t581, %t582
  %t584 = load i32, ptr %t11
  %t585 = add i32 %t583, %t584
  %t586 = load i32, ptr %t11
  %t587 = add i32 %t585, %t586
  %t588 = load i32, ptr %t11
  %t589 = add i32 %t587, %t588
  %t590 = load i32, ptr %t11
  %t591 = add i32 %t589, %t590
  %t592 = load i32, ptr %t11
  %t593 = add i32 %t591, %t592
  %t594 = load i32, ptr %t11
  %t595 = add i32 %t593, %t594
  %t596 = load i32, ptr %t11
  %t597 = add i32 %t595, %t596
  %t598 = load i32, ptr %t11
  %t599 = add i32 %t597, %t598
  %t600 = load i32, ptr %t11
  %t601 = add i32 %t599, %t600
  %t602 = load i32, ptr %t11
  %t603 = add i32 %t601, %t602
  %t604 = load i32, ptr %t11
  %t605 = add i32 %t603, %t604
  %t606 = load i32, ptr %t11
  %t607 = add i32 %t605, %t606
  %t608 = load i32, ptr %t11
  %t609 = add i32 %t607, %t608
  %t610 = load i32, ptr %t11
  %t611 = add i32 %t609, %t610
  %t612 = load i32, ptr %t11
  %t613 = add i32 %t611, %t612
  %t614 = load i32, ptr %t11
  %t615 = add i32 %t613, %t614
  %t616 = load i32, ptr %t11
  %t617 = add i32 %t615, %t616
  %t618 = load i32, ptr %t11
  %t619 = add i32 %t617, %t618
  %t620 = load i32, ptr %t11
  %t621 = add i32 %t619, %t620
  %t622 = load i32, ptr %t11
  %t623 = add i32 %t621, %t622
  %t624 = load i32, ptr %t11
  %t625 = add i32 %t623, %t624
  %t626 = load i32, ptr %t11
  %t627 = add i32 %t625, %t626
  %t628 = load i32, ptr %t11
  %t629 = add i32 %t627, %t628
  %t630 = load i32, ptr %t11
  %t631 = add i32 %t629, %t630
  %t632 = load i32, ptr %t11
  %t633 = add i32 %t631, %t632
  %t634 = load i32, ptr %t11
  %t635 = add i32 %t633, %t634
  %t636 = load i32, ptr %t11
  %t637 = add i32 %t635, %t636
  %t638 = load i32, ptr %t11
  %t639 = add i32 %t637, %t638
  %t640 = load i32, ptr %t11
  %t641 = add i32 %t639, %t640
  %t642 = load i32, ptr %t11
  %t643 = add i32 %t641, %t642
  %t644 = load i32, ptr %t11
  %t645 = add i32 %t643, %t644
  %t646 = load i32, ptr %t11
  %t647 = add i32 %t645, %t646
  %t648 = load i32, ptr %t11
  %t649 = add i32 %t647, %t648
  %t650 = load i32, ptr %t11
  %t651 = add i32 %t649, %t650
  %t652 = load i32, ptr %t11
  %t653 = add i32 %t651, %t652
  %t654 = load i32, ptr %t11
  %t655 = add i32 %t653, %t654
  %t656 = load i32, ptr %t11
  %t657 = add i32 %t655, %t656
  %t658 = load i32, ptr %t11
  %t659 = add i32 %t657, %t658
  %t660 = load i32, ptr %t11
  %t661 = add i32 %t659, %t660
  %t662 = load i32, ptr %t11
  %t663 = add i32 %t661, %t662
  %t664 = load i32, ptr %t11
  %t665 = add i32 %t663, %t664
  %t666 = load i32, ptr %t11
  %t667 = add i32 %t665, %t666
  %t668 = load i32, ptr %t11
  %t669 = add i32 %t667, %t668
  %t670 = load i32, ptr %t11
  %t671 = add i32 %t669, %t670
  %t672 = load i32, ptr %t11
  %t673 = add i32 %t671, %t672
  %t674 = load i32, ptr %t11
  %t675 = add i32 %t673, %t674
  %t676 = load i32, ptr %t11
  %t677 = add i32 %t675, %t676
  %t678 = load i32, ptr %t11
  %t679 = add i32 %t677, %t678
  %t680 = load i32, ptr %t11
  %t681 = add i32 %t679, %t680
  %t682 = load i32, ptr %t11
  %t683 = add i32 %t681, %t682
  %t684 = load i32, ptr %t11
  %t685 = add i32 %t683, %t684
  %t686 = load i32, ptr %t11
  %t687 = add i32 %t685, %t686
  %t688 = load i32, ptr %t11
  %t689 = add i32 %t687, %t688
  %t690 = load i32, ptr %t11
  %t691 = add i32 %t689, %t690
  %t692 = load i32, ptr %t11
  %t693 = add i32 %t691, %t692
  %t694 = load i32, ptr %t11
  %t695 = add i32 %t693, %t694
  %t696 = load i32, ptr %t11
  %t697 = add i32 %t695, %t696
  %t698 = load i32, ptr %t11
  %t699 = add i32 %t697, %t698
  %t700 = add i32 %t699, 12
  store i32 %t700, ptr %t9
  store i32 105, ptr %t10
  br label %L40110
L40110:
  %t701 = load i32, ptr %t9
  %t702 = sub i32 %t701, 105
  %t703 = icmp slt i32 %t702, 0
  br i1 %t703, label %L20110, label %arith_if_zero31
arith_if_zero31:
  %t704 = icmp eq i32 %t702, 0
  br i1 %t704, label %L10110, label %L20110
L30110:
  %t705 = load i32, ptr %t6
  %t706 = add i32 %t705, 1
  store i32 %t706, ptr %t6
  br label %bb197
bb197:
  %t707 = load i32, ptr %t3
  %t708 = load i32, ptr %t8
  %t709 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t710 = alloca i32, i32 1
  %t711 = getelementptr i32, ptr %t710, i32 0
  store i32 %t708, ptr %t711
  %t712 = alloca ptr, i32 1
  %t713 = getelementptr ptr, ptr %t712, i32 0
  store ptr %t711, ptr %t713
  %t714 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t707, ptr %t709, ptr %t712, ptr %t714, i32 1, i32 0)
  br label %bb198
bb198:
  %t715 = load i32, ptr %t7
  %t716 = icmp slt i32 %t715, 0
  br i1 %t716, label %L10110, label %arith_if_zero32
arith_if_zero32:
  %t717 = icmp eq i32 %t715, 0
  br i1 %t717, label %L121, label %L20110
L10110:
  %t718 = load i32, ptr %t4
  %t719 = add i32 %t718, 1
  store i32 %t719, ptr %t4
  br label %bb200
bb200:
  %t720 = load i32, ptr %t3
  %t721 = load i32, ptr %t8
  %t722 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t723 = alloca i32, i32 1
  %t724 = getelementptr i32, ptr %t723, i32 0
  store i32 %t721, ptr %t724
  %t725 = alloca ptr, i32 1
  %t726 = getelementptr ptr, ptr %t725, i32 0
  store ptr %t724, ptr %t726
  %t727 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t720, ptr %t722, ptr %t725, ptr %t727, i32 1, i32 0)
  br label %bb201
bb201:
  br label %L121
L20110:
  %t728 = load i32, ptr %t5
  %t729 = add i32 %t728, 1
  store i32 %t729, ptr %t5
  br label %bb203
bb203:
  %t730 = load i32, ptr %t3
  %t731 = load i32, ptr %t8
  %t732 = load i32, ptr %t9
  %t733 = load i32, ptr %t10
  %t734 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t735 = alloca i32, i32 3
  %t736 = getelementptr i32, ptr %t735, i32 0
  store i32 %t731, ptr %t736
  %t737 = getelementptr i32, ptr %t735, i32 1
  store i32 %t732, ptr %t737
  %t738 = getelementptr i32, ptr %t735, i32 2
  store i32 %t733, ptr %t738
  %t739 = alloca ptr, i32 3
  %t740 = getelementptr ptr, ptr %t739, i32 0
  store ptr %t736, ptr %t740
  %t741 = getelementptr ptr, ptr %t739, i32 1
  store ptr %t737, ptr %t741
  %t742 = getelementptr ptr, ptr %t739, i32 2
  store ptr %t738, ptr %t742
  %t743 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t730, ptr %t734, ptr %t739, ptr %t743, i32 3, i32 0)
  br label %L121
L121:
  br label %bb205
bb205:
  store i32 12, ptr %t8
  %t744 = load i32, ptr %t7
  %t745 = icmp slt i32 %t744, 0
  br i1 %t745, label %L30120, label %arith_if_zero33
arith_if_zero33:
  %t746 = icmp eq i32 %t744, 0
  br i1 %t746, label %L120, label %L30120
L120:
  br label %bb208
bb208:
  store i32 0, ptr %t11
  br label %L122
L122:
  store i32 89, ptr %t11
  br label %bb211
bb211:
  %t747 = load i32, ptr %t11
  store i32 %t747, ptr %t9
  store i32 89, ptr %t10
  br label %L40120
L40120:
  %t748 = load i32, ptr %t9
  %t749 = sub i32 %t748, 89
  %t750 = icmp slt i32 %t749, 0
  br i1 %t750, label %L20120, label %arith_if_zero34
arith_if_zero34:
  %t751 = icmp eq i32 %t749, 0
  br i1 %t751, label %L10120, label %L20120
L30120:
  %t752 = load i32, ptr %t6
  %t753 = add i32 %t752, 1
  store i32 %t753, ptr %t6
  br label %bb215
bb215:
  %t754 = load i32, ptr %t3
  %t755 = load i32, ptr %t8
  %t756 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t757 = alloca i32, i32 1
  %t758 = getelementptr i32, ptr %t757, i32 0
  store i32 %t755, ptr %t758
  %t759 = alloca ptr, i32 1
  %t760 = getelementptr ptr, ptr %t759, i32 0
  store ptr %t758, ptr %t760
  %t761 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t754, ptr %t756, ptr %t759, ptr %t761, i32 1, i32 0)
  br label %bb216
bb216:
  %t762 = load i32, ptr %t7
  %t763 = icmp slt i32 %t762, 0
  br i1 %t763, label %L10120, label %arith_if_zero35
arith_if_zero35:
  %t764 = icmp eq i32 %t762, 0
  br i1 %t764, label %L131, label %L20120
L10120:
  %t765 = load i32, ptr %t4
  %t766 = add i32 %t765, 1
  store i32 %t766, ptr %t4
  br label %bb218
bb218:
  %t767 = load i32, ptr %t3
  %t768 = load i32, ptr %t8
  %t769 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t770 = alloca i32, i32 1
  %t771 = getelementptr i32, ptr %t770, i32 0
  store i32 %t768, ptr %t771
  %t772 = alloca ptr, i32 1
  %t773 = getelementptr ptr, ptr %t772, i32 0
  store ptr %t771, ptr %t773
  %t774 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t767, ptr %t769, ptr %t772, ptr %t774, i32 1, i32 0)
  br label %bb219
bb219:
  br label %L131
L20120:
  %t775 = load i32, ptr %t5
  %t776 = add i32 %t775, 1
  store i32 %t776, ptr %t5
  br label %bb221
bb221:
  %t777 = load i32, ptr %t3
  %t778 = load i32, ptr %t8
  %t779 = load i32, ptr %t9
  %t780 = load i32, ptr %t10
  %t781 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t782 = alloca i32, i32 3
  %t783 = getelementptr i32, ptr %t782, i32 0
  store i32 %t778, ptr %t783
  %t784 = getelementptr i32, ptr %t782, i32 1
  store i32 %t779, ptr %t784
  %t785 = getelementptr i32, ptr %t782, i32 2
  store i32 %t780, ptr %t785
  %t786 = alloca ptr, i32 3
  %t787 = getelementptr ptr, ptr %t786, i32 0
  store ptr %t783, ptr %t787
  %t788 = getelementptr ptr, ptr %t786, i32 1
  store ptr %t784, ptr %t788
  %t789 = getelementptr ptr, ptr %t786, i32 2
  store ptr %t785, ptr %t789
  %t790 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t777, ptr %t781, ptr %t786, ptr %t790, i32 3, i32 0)
  br label %L131
L131:
  br label %bb223
bb223:
  store i32 13, ptr %t8
  %t791 = load i32, ptr %t7
  %t792 = icmp slt i32 %t791, 0
  br i1 %t792, label %L30130, label %arith_if_zero36
arith_if_zero36:
  %t793 = icmp eq i32 %t791, 0
  br i1 %t793, label %L130, label %L30130
L130:
  br label %bb226
bb226:
  store i32 0, ptr %t9
  br label %L132
L132:
  store i32 4, ptr %t9
  br label %bb228
bb228:
  store i32 4, ptr %t10
  br label %L40130
L40130:
  %t794 = load i32, ptr %t9
  %t795 = sub i32 %t794, 4
  %t796 = icmp slt i32 %t795, 0
  br i1 %t796, label %L20130, label %arith_if_zero37
arith_if_zero37:
  %t797 = icmp eq i32 %t795, 0
  br i1 %t797, label %L10130, label %L20130
L30130:
  %t798 = load i32, ptr %t6
  %t799 = add i32 %t798, 1
  store i32 %t799, ptr %t6
  br label %bb231
bb231:
  %t800 = load i32, ptr %t3
  %t801 = load i32, ptr %t8
  %t802 = getelementptr [23 x i8], ptr @str9, i32 0, i32 0
  %t803 = alloca i32, i32 1
  %t804 = getelementptr i32, ptr %t803, i32 0
  store i32 %t801, ptr %t804
  %t805 = alloca ptr, i32 1
  %t806 = getelementptr ptr, ptr %t805, i32 0
  store ptr %t804, ptr %t806
  %t807 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t800, ptr %t802, ptr %t805, ptr %t807, i32 1, i32 0)
  br label %bb232
bb232:
  %t808 = load i32, ptr %t7
  %t809 = icmp slt i32 %t808, 0
  br i1 %t809, label %L10130, label %arith_if_zero38
arith_if_zero38:
  %t810 = icmp eq i32 %t808, 0
  br i1 %t810, label %L141, label %L20130
L10130:
  %t811 = load i32, ptr %t4
  %t812 = add i32 %t811, 1
  store i32 %t812, ptr %t4
  br label %bb234
bb234:
  %t813 = load i32, ptr %t3
  %t814 = load i32, ptr %t8
  %t815 = getelementptr [21 x i8], ptr @str11, i32 0, i32 0
  %t816 = alloca i32, i32 1
  %t817 = getelementptr i32, ptr %t816, i32 0
  store i32 %t814, ptr %t817
  %t818 = alloca ptr, i32 1
  %t819 = getelementptr ptr, ptr %t818, i32 0
  store ptr %t817, ptr %t819
  %t820 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t813, ptr %t815, ptr %t818, ptr %t820, i32 1, i32 0)
  br label %bb235
bb235:
  br label %L141
L20130:
  %t821 = load i32, ptr %t5
  %t822 = add i32 %t821, 1
  store i32 %t822, ptr %t5
  br label %bb237
bb237:
  %t823 = load i32, ptr %t3
  %t824 = load i32, ptr %t8
  %t825 = load i32, ptr %t9
  %t826 = load i32, ptr %t10
  %t827 = getelementptr [46 x i8], ptr @str12, i32 0, i32 0
  %t828 = alloca i32, i32 3
  %t829 = getelementptr i32, ptr %t828, i32 0
  store i32 %t824, ptr %t829
  %t830 = getelementptr i32, ptr %t828, i32 1
  store i32 %t825, ptr %t830
  %t831 = getelementptr i32, ptr %t828, i32 2
  store i32 %t826, ptr %t831
  %t832 = alloca ptr, i32 3
  %t833 = getelementptr ptr, ptr %t832, i32 0
  store ptr %t829, ptr %t833
  %t834 = getelementptr ptr, ptr %t832, i32 1
  store ptr %t830, ptr %t834
  %t835 = getelementptr ptr, ptr %t832, i32 2
  store ptr %t831, ptr %t835
  %t836 = getelementptr [4 x i8], ptr @str13, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t823, ptr %t827, ptr %t832, ptr %t836, i32 3, i32 0)
  br label %L141
L141:
  br label %bb239
bb239:
  %t837 = load i32, ptr %t3
  %t838 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t837, ptr %t838, ptr null, ptr null, i32 0, i32 0)
  br label %bb240
bb240:
  %t839 = load i32, ptr %t3
  %t840 = getelementptr [54 x i8], ptr @str8, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t839, ptr %t840, ptr null, ptr null, i32 0, i32 0)
  br label %bb241
bb241:
  %t841 = load i32, ptr %t3
  %t842 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t841, ptr %t842, ptr null, ptr null, i32 0, i32 0)
  br label %bb242
bb242:
  %t843 = load i32, ptr %t3
  %t844 = getelementptr [43 x i8], ptr @str14, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t843, ptr %t844, ptr null, ptr null, i32 0, i32 0)
  br label %bb243
bb243:
  %t845 = load i32, ptr %t3
  %t846 = getelementptr [3 x i8], ptr @str3, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t845, ptr %t846, ptr null, ptr null, i32 0, i32 0)
  br label %bb244
bb244:
  %t847 = load i32, ptr %t3
  %t848 = load i32, ptr %t5
  %t849 = getelementptr [38 x i8], ptr @str15, i32 0, i32 0
  %t850 = alloca i32, i32 1
  %t851 = getelementptr i32, ptr %t850, i32 0
  store i32 %t848, ptr %t851
  %t852 = alloca ptr, i32 1
  %t853 = getelementptr ptr, ptr %t852, i32 0
  store ptr %t851, ptr %t853
  %t854 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t847, ptr %t849, ptr %t852, ptr %t854, i32 1, i32 0)
  br label %bb245
bb245:
  %t855 = load i32, ptr %t3
  %t856 = load i32, ptr %t4
  %t857 = getelementptr [38 x i8], ptr @str16, i32 0, i32 0
  %t858 = alloca i32, i32 1
  %t859 = getelementptr i32, ptr %t858, i32 0
  store i32 %t856, ptr %t859
  %t860 = alloca ptr, i32 1
  %t861 = getelementptr ptr, ptr %t860, i32 0
  store ptr %t859, ptr %t861
  %t862 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t855, ptr %t857, ptr %t860, ptr %t862, i32 1, i32 0)
  br label %bb246
bb246:
  %t863 = load i32, ptr %t3
  %t864 = load i32, ptr %t6
  %t865 = getelementptr [39 x i8], ptr @str17, i32 0, i32 0
  %t866 = alloca i32, i32 1
  %t867 = getelementptr i32, ptr %t866, i32 0
  store i32 %t864, ptr %t867
  %t868 = alloca ptr, i32 1
  %t869 = getelementptr ptr, ptr %t868, i32 0
  store ptr %t867, ptr %t869
  %t870 = getelementptr [2 x i8], ptr @str10, i32 0, i32 0
  call i32 @col6forge_write_v(i32 %t863, ptr %t865, ptr %t868, ptr %t870, i32 1, i32 0)
  br label %bb247
bb247:
  ret void
L90001:
  br label %L90000
L90000:
  br label %L80000
L80000:
  br label %L80002
L80002:
  br label %L80010
L80010:
  br label %L80012
L80012:
  br label %L80018
L80018:
  br label %L90002
L90002:
  br label %L90004
L90004:
  br label %L90006
L90006:
  br label %L90008
L90008:
  br label %L90010
L90010:
  br label %L90012
L90012:
  br label %L90014
L90014:
  br label %L90016
L90016:
  br label %L90020
L90020:
  br label %L90022
L90022:
  br label %L90024
L90024:
  br label %exit
exit:
  ret void
}
@str0 = private unnamed_addr constant [3 x i8] c"1\0A\00", align 1
@str1 = private unnamed_addr constant [47 x i8] c"           FORTRAN COMPILER VALIDATION SYSTEM\0A\00", align 1
@str2 = private unnamed_addr constant [35 x i8] c"                      VERSION 2.1\0A\00", align 1
@str3 = private unnamed_addr constant [3 x i8] c" \0A\00", align 1
@str4 = private unnamed_addr constant [49 x i8] c"         FOR OFFICIAL USE ONLY - COPYRIGHT 1978\0A\00", align 1
@str5 = private unnamed_addr constant [38 x i8] c"                   SUBSET LEVEL TEST\0A\00", align 1
@str6 = private unnamed_addr constant [32 x i8] c"                         FM200\0A\00", align 1
@str7 = private unnamed_addr constant [54 x i8] c"      TEST     PASS/FAIL     COMPUTED        CORRECT\0A\00", align 1
@str8 = private unnamed_addr constant [54 x i8] c"      ----------------------------------------------\0A\00", align 1
@str9 = private unnamed_addr constant [23 x i8] c"     %5d      DELETED\0A\00", align 1
@str10 = private unnamed_addr constant [2 x i8] c"i\00", align 1
@str11 = private unnamed_addr constant [21 x i8] c"     %5d       PASS\0A\00", align 1
@str12 = private unnamed_addr constant [46 x i8] c"     %5d       FAIL          %6d         %6d\0A\00", align 1
@str13 = private unnamed_addr constant [4 x i8] c"iii\00", align 1
@str14 = private unnamed_addr constant [43 x i8] c"                     END OF PROGRAM FM200\0A\00", align 1
@str15 = private unnamed_addr constant [38 x i8] c"                    %5d TESTS FAILED\0A\00", align 1
@str16 = private unnamed_addr constant [38 x i8] c"                    %5d TESTS PASSED\0A\00", align 1
@str17 = private unnamed_addr constant [39 x i8] c"                    %5d TESTS DELETED\0A\00", align 1
define i32 @main() {
entry:
  call void @fm200_()
  ret i32 0
}
declare i32 @col6forge_write_v(i32, ptr, ptr, ptr, i32, i32)
