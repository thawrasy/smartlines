/* @ds-bundle: {"format": 4, "namespace": "Masslak", "components": [{"name": "Logo"}, {"name": "Icon"}, {"name": "Button"}, {"name": "IconButton"}, {"name": "TextField"}, {"name": "Chip"}, {"name": "StatusBadge"}, {"name": "SegmentedButton"}, {"name": "Card"}, {"name": "Stat"}, {"name": "Banner"}, {"name": "Snackbar"}, {"name": "TopAppBar"}, {"name": "NavigationDrawer"}, {"name": "NavigationBar"}, {"name": "TripCard"}, {"name": "StopTimeline"}, {"name": "SeatMap"}, {"name": "Ticket"}, {"name": "DataTable"}, {"name": "Dialog"}]} */
(function () {
var ICONS = {"search":"M378-329q-108.16 0-183.08-75Q120-479 120-585t75-181q75-75 181.5-75t181 75Q632-691 632-584.85 632-542 618-502q-14 40-42 75l242 240q9 8.56 9 21.78T818-143q-9 9-22.22 9-13.22 0-21.78-9L533-384q-30 26-69.96 40.5Q423.08-329 378-329Zm-1-60q81.25 0 138.13-57.5Q572-504 572-585t-56.87-138.5Q458.25-781 377-781q-82.08 0-139.54 57.5Q180-666 180-585t57.46 138.5Q294.92-389 377-389Z","swap_horiz":"m194-323 100 100q9 9 9 21t-9 21q-9 9-21 9t-21-9L101-332q-5-5-7-10t-2-11q0-6 2-11t7-10l151-151q9-9 21-9t21 9q9 9 9 21t-9 21L194-383h286q13 0 21.5 8.5T510-353q0 13-8.5 21.5T480-323H194Zm572-254H480q-13 0-21.5-8.5T450-607q0-13 8.5-21.5T480-637h286L666-737q-9-9-9-21t9-21q9-9 21-9t21 9l151 151q5 5 7 10t2 11q0 6-2 11t-7 10L708-435q-9 9-21 9t-21-9q-9-9-9-21t9-21l100-100Z","directions_bus":"M302-202v39q0 18-12.5 30.5T259-120q-18 0-30.5-12.5T216-163v-68q-29-16-42.5-46T160-341v-397q0-74 76.5-108T481-880q166 0 242.5 34T800-738v397q0 34-13.5 64T744-231v68q0 18-12.5 30.5T701-120q-18 0-30.5-12.5T658-163v-39H302Zm179-562h259-520 261Zm177 293H220h520-82Zm-438-60h520v-173H220v173Zm145 203q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16Zm308 0q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16ZM220-764h520q-24-26-92-41t-167-15q-118 0-181 13.5T220-764Zm82 502h356q35 0 58.5-27t23.5-62v-120H220v120q0 35 23.5 62t58.5 27Z","confirmation_number":"M140-160q-24.75 0-42.37-17.63Q80-195.25 80-220v-132q0-10.19 5.5-17.59Q91-377 100-380q31-11 48.5-39.5t17.5-60q0-31.5-17.5-60.5T100-580q-9-3-14.5-10.41Q80-597.81 80-608v-132q0-24.75 17.63-42.38Q115.25-800 140-800h680q24.75 0 42.38 17.62Q880-764.75 880-740v132q0 10.19-5.5 17.59Q869-583 860-580q-31 11-48.5 40T794-479.5q0 31.5 17.5 60T860-380q9 3 14.5 10.41 5.5 7.4 5.5 17.59v132q0 24.75-17.62 42.37Q844.75-160 820-160H140Zm0-60h680v-109q-38-26-62-65t-24-86q0-47 24-86t62-65v-109H140v109q39 26 62.5 65t23.5 86q0 47-23.5 86T140-329v109Zm340-63q12 0 21-9t9-21q0-12-9-21t-21-9q-12 0-21 9t-9 21q0 12 9 21t21 9Zm0-167q12 0 21-9t9-21q0-12-9-21t-21-9q-12 0-21 9t-9 21q0 12 9 21t21 9Zm0-167q12 0 21-9t9-21q0-12-9-21t-21-9q-12 0-21 9t-9 21q0 12 9 21t21 9Zm0 137Z","account_balance_wallet":"M180-233v53-600 547Zm0 113q-24.75 0-42.37-17.63Q120-155.25 120-180v-600q0-24.75 17.63-42.38Q155.25-840 180-840h600q24.75 0 42.38 17.62Q840-804.75 840-780v134h-60v-134H180v600h600v-133h60v133q0 24.75-17.62 42.37Q804.75-120 780-120H180Zm358-173q-30.52 0-52.26-21.44Q464-335.89 464-366v-227q0-30.11 21.74-51.56Q507.48-666 538-666h270q30.53 0 52.26 21.44Q882-623.11 882-593v227q0 30.11-21.74 51.56Q838.53-293 808-293H538Zm284-60v-253H524v253h298Zm-124.5-81.96Q716-453.92 716-481q0-26.25-19-44.63Q678-544 652-544t-45 18.37q-19 18.38-19 44.63 0 27.08 18.74 46.04Q625.47-416 652.24-416q26.76 0 45.26-18.96Z","person":"M372-523q-42-42-42-108t42-108q42-42 108-42t108 42q42 42 42 108t-42 108q-42 42-108 42t-108-42ZM160-220v-34q0-38 19-65t49-41q67-30 128.5-45T480-420q62 0 123 15.5T731-360q31 14 50 41t19 65v34q0 25-17.5 42.5T740-160H220q-25 0-42.5-17.5T160-220Zm60 0h520v-34q0-16-9.5-30.5T707-306q-64-31-117-42.5T480-360q-57 0-111 11.5T252-306q-14 7-23 21.5t-9 30.5v34Zm324.5-346.5Q570-592 570-631t-25.5-64.5Q519-721 480-721t-64.5 25.5Q390-670 390-631t25.5 64.5Q441-541 480-541t64.5-25.5ZM480-631Zm0 411Z","event":"M528-248.18q-28-28.19-28-69Q500-358 528.18-386q28.19-28 69-28Q638-414 666-385.82q28 28.19 28 69Q694-276 665.82-248q-28.19 28-69 28Q556-220 528-248.18ZM180-80q-24 0-42-18t-18-42v-620q0-24 18-42t42-18h65v-28q0-13.6 9-22.8 9-9.2 23.02-9.2t23.5 9.2Q310-861.6 310-848v28h340v-28q0-13.6 9-22.8 9-9.2 23.02-9.2t23.5 9.2Q715-861.6 715-848v28h65q24 0 42 18t18 42v620q0 24-18 42t-42 18H180Zm0-60h600v-430H180v430Zm0-490h600v-130H180v130Zm0 0v-130 130Z","group":"M38-254q0-35 18-63.5t50-42.5q73-32 131.5-46T358-420q62 0 120 14t131 46q32 14 50.5 42.5T678-254v34q0 25-17.5 42.5T618-160H98q-25 0-42.5-17.5T38-220v-34Zm824 94H724q5-15 9.5-29.5T738-220v-34q0-63-29-101.5T622-420q69 8 130 22t99 34q33 19 52 47t19 63v34q0 25-17.5 42.5T862-160ZM250-523q-42-42-42-108t42-108q42-42 108-42t108 42q42 42 42 108t-42 108q-42 42-108 42t-108-42Zm426 0q-42 42-108 42-11 0-24.5-1.5T519-488q24-25 36.5-61.5T568-631q0-45-12.5-79.5T519-774q11-3 24.5-5t24.5-2q66 0 108 42t42 108q0 66-42 108ZM98-220h520v-34q0-16-9.5-31T585-306q-72-32-121-43t-106-11q-57 0-106.5 11T130-306q-14 6-23 21t-9 31v34Zm324.5-346.5Q448-592 448-631t-25.5-64.5Q397-721 358-721t-64.5 25.5Q268-670 268-631t25.5 64.5Q319-541 358-541t64.5-25.5ZM358-220Zm0-411Z","schedule":"M513-492v-171q0-13-8.5-21.5T483-693q-13 0-21.5 8.5T453-663v183q0 6 2 11t6 10l144 149q9 10 22.5 9.5T650-310q9-9 9-22t-9-22L513-492ZM480-80q-82 0-155-31.5t-127.5-86Q143-252 111.5-325T80-480q0-82 31.5-155t86-127.5Q252-817 325-848.5T480-880q82 0 155 31.5t127.5 86Q817-708 848.5-635T880-480q0 82-31.5 155t-86 127.5Q708-143 635-111.5T480-80Zm0-400Zm0 340q140 0 240-100t100-240q0-140-100-240T480-820q-140 0-240 100T140-480q0 140 100 240t240 100Z","location_on":"M480-159q133-121 196.5-219.5T740-552q0-118-75.5-193T480-820q-109 0-184.5 75T220-552q0 75 65 173.5T480-159Zm-21.5 55.5Q448-107 440-115q-42-38-91-87.5T258-309q-42-57-70-119t-28-124q0-150 96.5-239T480-880q127 0 223.5 89T800-552q0 62-28 124t-70 119q-42 57-91 106.5T520-115q-8 8-18.5 11.5T480-100q-11 0-21.5-3.5ZM480-560Zm49.5 49.5Q550-531 550-560t-20.5-49.5Q509-630 480-630t-49.5 20.5Q410-589 410-560t20.5 49.5Q451-490 480-490t49.5-20.5Z","check_circle":"m421-389-98-98q-9-9-22-9t-23 10q-9 9-9 22t9 22l122 123q9 9 21 9t21-9l239-239q10-10 10-23t-10-23q-10-9-23.5-8.5T635-603L421-389Zm59 309q-82 0-155-31.5t-127.5-86Q143-252 111.5-325T80-480q0-83 31.5-156t86-127Q252-817 325-848.5T480-880q83 0 156 31.5T763-763q54 54 85.5 127T880-480q0 82-31.5 155T763-197.5q-54 54.5-127 86T480-80Zm0-60q142 0 241-99.5T820-480q0-142-99-241t-241-99q-141 0-240.5 99T140-480q0 141 99.5 240.5T480-140Zm0-340Z","error":"M503.5-289.48q9.5-9.48 9.5-23.5t-9.48-23.52q-9.48-9.5-23.5-9.5t-23.52 9.48q-9.5 9.48-9.5 23.5t9.48 23.52q9.48 9.5 23.5 9.5t23.52-9.48Zm1-152.15q8.5-8.62 8.5-21.37v-193q0-12.75-8.68-21.38-8.67-8.62-21.5-8.62-12.82 0-21.32 8.62-8.5 8.63-8.5 21.38v193q0 12.75 8.68 21.37 8.67 8.63 21.5 8.63 12.82 0 21.32-8.63ZM480.27-80q-82.74 0-155.5-31.5Q252-143 197.5-197.5t-86-127.34Q80-397.68 80-480.5t31.5-155.66Q143-709 197.5-763t127.34-85.5Q397.68-880 480.5-880t155.66 31.5Q709-817 763-763t85.5 127Q880-563 880-480.27q0 82.74-31.5 155.5Q817-252 763-197.68q-54 54.31-127 86Q563-80 480.27-80Zm.23-60Q622-140 721-239.5t99-241Q820-622 721.19-721T480-820q-141 0-240.5 98.81T140-480q0 141 99.5 240.5t241 99.5Zm-.5-340Z","qr_code_2":"M520-120v-80h80v80h-80Zm-80-80v-200h80v200h-80Zm320-120v-160h80v160h-80Zm-80-160v-80h80v80h-80Zm-480 80v-80h80v80h-80Zm-80-80v-80h80v80h-80Zm360-280v-80h80v80h-80ZM170-650h140v-140H170v140Zm-50 20v-180q0-12.75 8.63-21.38Q137.25-840 150-840h180q12.75 0 21.38 8.62Q360-822.75 360-810v180q0 12.75-8.62 21.37Q342.75-600 330-600H150q-12.75 0-21.37-8.63Q120-617.25 120-630Zm50 460h140v-140H170v140Zm-50 20v-180q0-12.75 8.63-21.38Q137.25-360 150-360h180q12.75 0 21.38 8.62Q360-342.75 360-330v180q0 12.75-8.62 21.37Q342.75-120 330-120H150q-12.75 0-21.37-8.63Q120-137.25 120-150Zm530-500h140v-140H650v140Zm-50 20v-180q0-12.75 8.63-21.38Q617.25-840 630-840h180q12.75 0 21.38 8.62Q840-822.75 840-810v180q0 12.75-8.62 21.37Q822.75-600 810-600H630q-12.75 0-21.37-8.63Q600-617.25 600-630Zm80 510v-120h-80v-80h160v120h80v80H680ZM520-400v-80h160v80H520Zm-160 0v-80h-80v-80h240v80h-80v80h-80Zm40-200v-160h80v80h80v80H400Zm-190-90v-60h60v60h-60Zm0 480v-60h60v60h-60Zm480-480v-60h60v60h-60Z","qr_code_scanner":"M109.82-707Q97-707 88.5-715.63 80-724.25 80-737v-113q0-12.75 8.63-21.38Q97.25-880 110-880h113q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5h-83v83q0 12.75-8.68 21.37-8.67 8.63-21.5 8.63ZM110-80q-12.75 0-21.37-8.63Q80-97.25 80-110v-113q0-12.75 8.68-21.38 8.67-8.62 21.5-8.62 12.82 0 21.32 8.62 8.5 8.63 8.5 21.38v83h83q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32Q235.75-80 223-80H110Zm627 0q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h83v-83q0-12.75 8.68-21.38 8.67-8.62 21.5-8.62 12.82 0 21.32 8.62 8.5 8.63 8.5 21.38v113q0 12.75-8.62 21.37Q862.75-80 850-80H737Zm91.5-635.63Q820-724.25 820-737v-83h-83q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h113q12.75 0 21.38 8.62Q880-862.75 880-850v113q0 12.75-8.68 21.37-8.67 8.63-21.5 8.63-12.82 0-21.32-8.63ZM708-188v-63h63v63h-63Zm0-126v-63h63v63h-63Zm-63 63v-63h63v63h-63Zm-63 63v-63h63v63h-63Zm-63-63v-63h63v63h-63Zm126-126v-63h63v63h-63Zm-63 63v-63h63v63h-63Zm-63-63v-63h63v63h-63Zm30-143q-12.75 0-21.37-8.63Q519-537.25 519-550v-192q0-12.75 8.63-21.38Q536.25-772 549-772h192q12.75 0 21.38 8.62Q771-754.75 771-742v192q0 12.75-8.62 21.37Q753.75-520 741-520H549ZM218-188q-12.75 0-21.37-8.63Q188-205.25 188-218v-192q0-12.75 8.63-21.38Q205.25-440 218-440h192q12.75 0 21.38 8.62Q440-422.75 440-410v192q0 12.75-8.62 21.37Q422.75-188 410-188H218Zm0-332q-12.75 0-21.37-8.63Q188-537.25 188-550v-192q0-12.75 8.63-21.38Q205.25-772 218-772h192q12.75 0 21.38 8.62Q440-754.75 440-742v192q0 12.75-8.62 21.37Q422.75-520 410-520H218Zm20 282h152v-152H238v152Zm0-332h152v-152H238v152Zm331 0h152v-152H569v152Z","dashboard":"M510-600v-210q0-12.75 8.63-21.38Q527.25-840 540-840h270q12.75 0 21.38 8.62Q840-822.75 840-810v210q0 12.75-8.62 21.37Q822.75-570 810-570H540q-12.75 0-21.37-8.63Q510-587.25 510-600ZM120-480v-330q0-12.75 8.63-21.38Q137.25-840 150-840h270q12.75 0 21.38 8.62Q450-822.75 450-810v330q0 12.75-8.62 21.37Q432.75-450 420-450H150q-12.75 0-21.37-8.63Q120-467.25 120-480Zm390 330v-330q0-12.75 8.63-21.38Q527.25-510 540-510h270q12.75 0 21.38 8.62Q840-492.75 840-480v330q0 12.75-8.62 21.37Q822.75-120 810-120H540q-12.75 0-21.37-8.63Q510-137.25 510-150Zm-390 0v-210q0-12.75 8.63-21.38Q137.25-390 150-390h270q12.75 0 21.38 8.62Q450-372.75 450-360v210q0 12.75-8.62 21.37Q432.75-120 420-120H150q-12.75 0-21.37-8.63Q120-137.25 120-150Zm60-360h210v-270H180v270Zm390 330h210v-270H570v270Zm0-450h210v-150H570v150ZM180-180h210v-150H180v150Zm210-330Zm180-120Zm0 180ZM390-330Z","route":"M245-165.53Q200-211.06 200-275v-349q-35-13-57.5-41.26-22.5-28.27-22.5-64.41Q120-776 152.5-808t78-32q45.5 0 77.5 32.14t32 78.05q0 35.81-22.5 64.31T260-624v349q0 39.19 27.5 67.09Q315-180 355.5-180t67.5-27.91q27-27.9 27-67.09v-410q0-65 45-110t110-45q65 0 110 45t45 110v349q35 13 57.5 41.36Q840-266.27 840-230q0 45-32.08 77.5Q775.83-120 730-120q-45 0-77.5-32.5T620-230q0-36.3 22.5-65.15Q665-324 700-336v-349q0-40-27.5-67.5T605-780q-40 0-67.5 27.5T510-685v410q0 63.94-45 109.47T355-120q-65 0-110-45.53ZM230.5-680q20.5 0 35-15t14.5-35.5q0-20.5-14.37-35Q251.25-780 230-780q-20 0-35 14.37-15 14.38-15 35.63 0 20 15 35t35.5 15Zm500 500q20.5 0 35-15t14.5-35.5q0-20.5-14.37-35Q751.25-280 730-280q-20 0-35 14.37-15 14.38-15 35.63 0 20 15 35t35.5 15ZM230-730Zm500 500Z","local_shipping":"M140.5-195.42Q106-229.83 106-279H70q-12.75 0-21.37-8.63Q40-296.25 40-309v-431q0-24 18-42t42-18h519q24.75 0 42.38 17.62Q679-764.75 679-740v107h75q14.25 0 27 6.37 12.75 6.38 21 17.63l112 149q3 3.75 4.5 8.25T920-442v133q0 12.75-8.62 21.37Q902.75-279 890-279h-41q0 49-34.38 83.5t-83.5 34.5q-49.12 0-83.62-34.42Q613-229.83 613-279H342q0 49-34.38 83.5t-83.5 34.5q-49.12 0-83.62-34.42ZM265-238q17-17 17-41t-17-41q-17-17-41-17t-41 17q-17 17-17 41t17 41q17 17 41 17t41-17ZM100-339h22q17-27 43.04-43t58-16q31.96 0 58.46 16.5T325-339h294v-401H100v401Zm672 101q17-17 17-41t-17-41q-17-17-41-17t-41 17q-17 17-17 41t17 41q17 17 41 17t41-17Zm-93-187h186L754-573h-75v148ZM360-540Z","add":"M450-450H230q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h220v-220q0-12.75 8.68-21.38 8.67-8.62 21.5-8.62 12.82 0 21.32 8.62 8.5 8.63 8.5 21.38v220h220q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H510v220q0 12.75-8.68 21.37-8.67 8.63-21.5 8.63-12.82 0-21.32-8.63-8.5-8.62-8.5-21.37v-220Z","verified":"m437-433-73-76q-9-10-22-10t-23 9q-10 10-10 23t10 23l97 96q9 9 21 9t21-9l183-182q9-9 9-22t-10-22q-9-8-21.5-7.5T598-593L437-433ZM332-84l-62-106-124-25q-11-2-18.5-12t-5.5-21l14-120-79-92q-8-8-8-20t8-20l79-91-14-120q-2-11 5.5-21t18.5-12l124-25 62-107q6-10 17-14t22 1l109 51 109-51q11-5 22-1.5t17 13.5l63 108 123 25q11 2 18.5 12t5.5 21l-14 120 79 91q8 8 8 20t-8 20l-79 92 14 120q2 11-5.5 21T814-215l-123 25-63 107q-6 10-17 13.5T589-71l-109-51-109 51q-11 5-22 1t-17-14Zm41-55 107-45 110 45 67-100 117-30-12-119 81-92-81-94 12-119-117-28-69-100-108 45-110-45-67 100-117 28 12 119-81 94 81 92-12 121 117 28 70 100Zm107-341Z","shield":"M470.12-85q-4.56-1-9.12-3-139-47-220-168.5t-81-266.61V-719q0-19.26 10.88-34.66Q181.75-769.07 199-776l260-97q11-4 21-4t21 4l260 97q17.25 6.93 28.13 22.34Q800-738.26 800-719v195.89Q800-378 719-256.5T499-88q-4.56 2-9.12 3T480-84q-5.32 0-9.88-1Zm9.88-58q115-38 187.5-143.5T740-523v-196l-260-98-260 98v196q0 131 72.5 236.5T480-143Zm0-337Z","notifications":"M190-200q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h50v-304q0-84 49.5-150.5T420-798v-22q0-25 17.5-42.5T480-880q25 0 42.5 17.5T540-820v22q81 17 130.5 83.5T720-564v304h50q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H190Zm290-302Zm0 422q-33 0-56.5-23.5T400-160h160q0 33-23.5 56.5T480-80ZM300-260h360v-304q0-75-52.5-127.5T480-744q-75 0-127.5 52.5T300-564v304Z","menu":"M150-240q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h660q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H150Zm0-210q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h660q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H150Zm0-210q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h660q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H150Z","arrow_back":"m274-450 227 227q9 9 9 21t-9 21q-9 9-21 9t-21-9L181-459q-5-5-7-10t-2-11q0-6 2-11t7-10l278-278q9-9 21-9t21 9q9 9 9 21t-9 21L274-510h496q13 0 21.5 8.5T800-480q0 13-8.5 21.5T770-450H274Z","chevron_right":"M530-481 353-658q-9-9-8.5-21t9.5-21q9-9 21.5-9t21.5 9l198 198q5 5 7 10t2 11q0 6-2 11t-7 10L396-261q-9 9-21 8.5t-21-9.5q-9-9-9-21.5t9-21.5l176-176Z","close":"M480-438 270-228q-9 9-21 9t-21-9q-9-9-9-21t9-21l210-210-210-210q-9-9-9-21t9-21q9-9 21-9t21 9l210 210 210-210q9-9 21-9t21 9q9 9 9 21t-9 21L522-480l210 210q9 9 9 21t-9 21q-9 9-21 9t-21-9L480-438Z","info":"M504.5-288.63q8.5-8.62 8.5-21.37v-180q0-12.75-8.68-21.38-8.67-8.62-21.5-8.62-12.82 0-21.32 8.62-8.5 8.63-8.5 21.38v180q0 12.75 8.68 21.37 8.67 8.63 21.5 8.63 12.82 0 21.32-8.63Zm-1-314.57q9.5-9.2 9.5-22.8 0-14.45-9.48-24.22-9.48-9.78-23.5-9.78t-23.52 9.78Q447-640.45 447-626q0 13.6 9.48 22.8 9.48 9.2 23.5 9.2t23.52-9.2ZM480.27-80q-82.74 0-155.5-31.5Q252-143 197.5-197.5t-86-127.34Q80-397.68 80-480.5t31.5-155.66Q143-709 197.5-763t127.34-85.5Q397.68-880 480.5-880t155.66 31.5Q709-817 763-763t85.5 127Q880-563 880-480.27q0 82.74-31.5 155.5Q817-252 763-197.68q-54 54.31-127 86Q563-80 480.27-80Zm.23-60Q622-140 721-239.5t99-241Q820-622 721.19-721T480-820q-141 0-240.5 98.81T140-480q0 141 99.5 240.5t241 99.5Zm-.5-340Z","warning":"M92-120q-9 0-15.5-4T66-135q-4-7-4.5-14.5T66-165l388-670q5-8 11.5-11.5T480-850q8 0 14.5 3.5T506-835l388 670q5 8 4.5 15.5T894-135q-4 7-10.5 11t-15.5 4H92Zm52-60h672L480-760 144-180Zm361.5-65.5Q514-254 514-267t-8.5-21.5Q497-297 484-297t-21.5 8.5Q454-280 454-267t8.5 21.5Q471-237 484-237t21.5-8.5Zm0-111Q514-365 514-378v-164q0-13-8.5-21.5T484-572q-13 0-21.5 8.5T454-542v164q0 13 8.5 21.5T484-348q13 0 21.5-8.5ZM480-470Z","airline_seat_recline_normal":"M590-171H300q-24.75 0-42.37-17.63Q240-206.25 240-231v-431q0-12.75 8.68-21.38 8.67-8.62 21.5-8.62 12.82 0 21.32 8.62 8.5 8.63 8.5 21.38v431h290q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5ZM438-718q-34 0-57.5-23.5T357-799q0-34 23.5-57.5T438-880q34 0 57.5 23.5T519-799q0 34-23.5 57.5T438-718Zm222 608v-161H415q-30.94 0-52.97-21.74Q340-314.48 340-345v-228q0-40.74 28.39-68.87Q396.77-670 437.89-670q41.11 0 69.61 28.13T536-573v202h109q30.94 0 52.97 21.74Q720-327.52 720-297v187q0 12.75-8.68 21.37-8.67 8.63-21.5 8.63-12.82 0-21.32-8.63Q660-97.25 660-110Z","settings":"M421-80q-14 0-25-9t-13-23l-15-94q-19-7-40-19t-37-25l-86 40q-14 6-28 1.5T155-226L97-330q-8-13-4.5-27t15.5-23l80-59q-2-9-2.5-20.5T185-480q0-9 .5-20.5T188-521l-80-59q-12-9-15.5-23t4.5-27l58-104q8-13 22-17.5t28 1.5l86 40q16-13 37-25t40-18l15-95q2-14 13-23t25-9h118q14 0 25 9t13 23l15 94q19 7 40.5 18.5T669-710l86-40q14-6 27.5-1.5T804-734l59 104q8 13 4.5 27.5T852-580l-80 57q2 10 2.5 21.5t.5 21.5q0 10-.5 21t-2.5 21l80 58q12 8 15.5 22.5T863-330l-58 104q-8 13-22 17.5t-28-1.5l-86-40q-16 13-36.5 25.5T592-206l-15 94q-2 14-13 23t-25 9H421Zm15-60h88l14-112q33-8 62.5-25t53.5-41l106 46 40-72-94-69q4-17 6.5-33.5T715-480q0-17-2-33.5t-7-33.5l94-69-40-72-106 46q-23-26-52-43.5T538-708l-14-112h-88l-14 112q-34 7-63.5 24T306-642l-106-46-40 72 94 69q-4 17-6.5 33.5T245-480q0 17 2.5 33.5T254-413l-94 69 40 72 106-46q24 24 53.5 41t62.5 25l14 112Zm44-210q54 0 92-38t38-92q0-54-38-92t-92-38q-54 0-92 38t-38 92q0 54 38 92t92 38Zm0-130Z","logout":"M180-120q-24 0-42-18t-18-42v-600q0-24 18-42t42-18h269q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H180v600h269q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H180Zm545-330H390q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h333l-81-81q-9-9-8.5-21t9.5-21q9-9 21.5-9t21.5 9l133 133q9 9 9 21t-9 21L687-326q-8.8 9-20.9 8.5-12.1-.5-21.49-9.5-8.61-9-8.61-21.5t9-21.5l80-80Z","language":"M323-111.5Q250-143 196-197t-85-127.5Q80-398 80-482t31-156.5Q142-711 196-765t127-84.5Q396-880 480-880t157 30.5Q710-819 764-765t85 126.5Q880-566 880-482t-31 157.5Q818-251 764-197t-127 85.5Q564-80 480-80t-157-31.5ZM480-138q35-36 58.5-82.5T577-331H384q14 60 37.5 108t58.5 85Zm-85-12q-25-38-43-82t-30-99H172q38 71 88 111.5T395-150Zm171-1q72-23 129.5-69T788-331H639q-13 54-30.5 98T566-151ZM152-391h159q-3-27-3.5-48.5T307-482q0-25 1-44.5t4-43.5H152q-7 24-9.5 43t-2.5 45q0 26 2.5 46.5T152-391Zm221 0h215q4-31 5-50.5t1-40.5q0-20-1-38.5t-5-49.5H373q-4 31-5 49.5t-1 38.5q0 21 1 40.5t5 50.5Zm275 0h160q7-24 9.5-44.5T820-482q0-26-2.5-45t-9.5-43H649q3 35 4 53.5t1 34.5q0 22-1.5 41.5T648-391Zm-10-239h150q-33-69-90.5-115T565-810q25 37 42.5 80T638-630Zm-254 0h194q-11-53-37-102.5T480-820q-32 27-54 71t-42 119Zm-212 0h151q11-54 28-96.5t43-82.5q-75 19-131 64t-91 115Z","home":"M220-180h150v-220q0-12.75 8.63-21.38Q387.25-430 400-430h160q12.75 0 21.38 8.62Q590-412.75 590-400v220h150v-390L480-765 220-570v390Zm-60 0v-390q0-14.25 6.38-27 6.37-12.75 17.62-21l260-195q15.68-12 35.84-12Q500-825 516-813l260 195q11.25 8.25 17.63 21 6.37 12.75 6.37 27v390q0 24.75-17.62 42.37Q764.75-120 740-120H560q-12.75 0-21.37-8.63Q530-137.25 530-150v-220H430v220q0 12.75-8.62 21.37Q412.75-120 400-120H220q-24.75 0-42.37-17.63Q160-155.25 160-180Zm320-293Z","sos":"M400-280q-24.75 0-42.37-17.63Q340-315.25 340-340v-280q0-24.75 17.63-42.38Q375.25-680 400-680h160q24.75 0 42.38 17.62Q620-644.75 620-620v280q0 24.75-17.62 42.37Q584.75-280 560-280H400Zm-180 0H70q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32Q57.25-340 70-340h150v-110H100q-24.75 0-42.37-17.63Q40-485.25 40-510v-110q0-24.75 17.63-42.38Q75.25-680 100-680h150q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H100v110h120q24.75 0 42.38 17.62Q280-474.75 280-450v110q0 24.75-17.62 42.37Q244.75-280 220-280Zm640 0H710q-12.75 0-21.37-8.68-8.63-8.67-8.63-21.5 0-12.82 8.63-21.32 8.62-8.5 21.37-8.5h150v-110H740q-24.75 0-42.37-17.63Q680-485.25 680-510v-110q0-24.75 17.63-42.38Q715.25-680 740-680h150q12.75 0 21.38 8.68 8.62 8.67 8.62 21.5 0 12.82-8.62 21.32-8.63 8.5-21.38 8.5H740v110h120q24.75 0 42.38 17.62Q920-474.75 920-450v110q0 24.75-17.62 42.37Q884.75-280 860-280Zm-460-60h160v-280H400v280Z","my_location":"M450-72v-45q-137-14-228-105T117-450H72q-13 0-21.5-8.5T42-480q0-13 8.5-21.5T72-510h45q14-137 105-228t228-105v-45q0-13 8.5-21.5T480-918q13 0 21.5 8.5T510-888v45q137 14 228 105t105 228h45q13 0 21.5 8.5T918-480q0 13-8.5 21.5T888-450h-45q-14 137-105 228T510-117v45q0 13-8.5 21.5T480-42q-13 0-21.5-8.5T450-72Zm244.5-193.5Q784-355 784-480t-89.5-214.5Q605-784 480-784t-214.5 89.5Q176-605 176-480t89.5 214.5Q355-176 480-176t214.5-89.5Zm-321-108Q330-417 330-480t43.5-106.5Q417-630 480-630t106.5 43.5Q630-543 630-480t-43.5 106.5Q543-330 480-330t-106.5-43.5ZM544-416q26-26 26-64t-26-64q-26-26-64-26t-64 26q-26 26-26 64t26 64q26 26 64 26t64-26Zm-64-64Z","bluetooth":"M450-136v-272L277-235q-9 9-21 9t-21-9q-9-9-9-21t9-21l203-203-203-203q-9-9-9-21t9-21q9-9 21-9t21 9l173 173v-272q0-14 9.5-22t20.5-8q5 0 10.5 2t10.5 7l172 172q5 5 7 10t2 11q0 6-2 11t-7 10L522-480l151 151q5 5 7 10t2 11q0 6-2 11t-7 10L501-115q-5 5-10.5 7t-10.5 2q-11 0-20.5-8t-9.5-22Zm60-416 100-100-100-98v198Zm0 342 100-98-100-100v198Z"};
  var R = window.React, h = R.createElement;
  function cx() { return Array.prototype.filter.call(arguments, Boolean).join(" "); }

  function Icon(p) {
    var size = p.size || 24, d = ICONS[p.name];
    if (!d) return null;
    return h("svg", { className: cx("ms-icon", p.flip && "ms-flip", p.className), width: size, height: size, viewBox: "0 -960 960 960", "aria-hidden": "true", focusable: "false" },
      h("path", { d: d, fill: "currentColor" }));
  }
  var DIRECTIONAL = { arrow_back: 1, chevron_right: 1, logout: 1 };
  function Ic(name, size) { return name ? h(Icon, { name: name, size: size || 20, flip: !!DIRECTIONAL[name] }) : null; }

  var ROUTE = "M15.5 43.5 C20.5 32.5 24.5 22 32.5 22 C39.5 22 41.5 32.5 48.5 34.5";
  function Mark(p) {
    var s = p.size || 36, tone = p.tone || "navy", onLight = tone === "outline" || tone === "symbol", white = tone === "white";
    var bare = tone === "symbol" || white;
    var stroke = white ? "#FFFFFF" : (onLight ? "#0A5BD3" : "#2F7BFF");
    var origin = white ? "#FFFFFF" : (onLight ? "#2F7BFF" : "#7FB0FF");
    return h("svg", { className: "ms-logo-mark", width: s, height: s, viewBox: bare ? "8 12 48 40" : "0 0 64 64", "aria-hidden": "true" },
      bare ? null : (tone === "outline"
        ? h("rect", { x: 2.5, y: 2.5, width: 59, height: 59, rx: 15, fill: "#FFFFFF", stroke: "#0B1F3F", strokeWidth: 4 })
        : h("rect", { width: 64, height: 64, rx: 16, fill: "#0B1F3F" })),
      h("path", { d: ROUTE, fill: "none", stroke: stroke, strokeWidth: 6, strokeLinecap: "round" }),
      h("circle", { cx: 15.5, cy: 43.5, r: 5, fill: origin }), h("circle", { cx: 48.5, cy: 34.5, r: 5, fill: "#12A06A" }));
  }
  function Logo(p) {
    var mark = h(Mark, { size: p.size || 36, tone: p.tone });
    if (!p.withName) return mark;
    var en = p.lang === "en";
    return h("span", { className: cx("ms-logo", p.tone === "white" && "ms-logo-white") }, mark,
      h("span", { className: "ms-logo-text" },
        h("span", { className: "ms-logo-name" }, h("b", null, en ? "Masslak" : "مسلك"), en ? null : h("span", { className: "ms-logo-latin" }, "masslak")),
        p.tagline ? h("small", null, p.tagline) : null));
  }

  function Button(p) {
    var v = p.variant || "filled", s = p.size || "md";
    var rest = Object.assign({}, p); ["variant", "size", "icon", "block", "children", "className", "trailingIcon"].forEach(function (k) { delete rest[k]; });
    return h("button", Object.assign({ type: "button" }, rest, { className: cx("ms-btn", "ms-btn-" + v, "ms-btn-" + s, p.block && "ms-block", p.className) }),
      Ic(p.icon, s === "sm" ? 18 : 20), h("span", null, p.children), Ic(p.trailingIcon, 20));
  }

  function IconButton(p) {
    return h("button", { type: "button", className: cx("ms-iconbtn", "ms-iconbtn-" + (p.variant || "standard")), "aria-label": p.label, title: p.label, onClick: p.onClick },
      Ic(p.icon, 24), p.badge ? h("span", { className: "ms-dot" }) : null);
  }

  var fid = 0;
  function TextField(p) {
    var id = R.useMemo(function () { return p.id || "ms-f-" + (++fid); }, []);
    var input = h(p.multiline ? "textarea" : "input", {
      id: id, className: cx("ms-input", p.filled && "ms-input-filled", p.error && "ms-input-error", p.icon && "ms-has-icon"),
      defaultValue: p.value, placeholder: p.placeholder, type: p.type || "text", dir: p.dir, readOnly: p.readOnly,
      "aria-invalid": p.error ? "true" : undefined, "aria-describedby": (p.hint || p.error) ? id + "-h" : undefined
    });
    return h("div", { className: "ms-field" },
      p.label ? h("label", { htmlFor: id, className: "ms-field-label" }, p.label, p.required ? h("span", { className: "ms-req" }, " *") : null) : null,
      h("div", { className: "ms-input-wrap" }, p.icon ? h("span", { className: "ms-input-icon" }, Ic(p.icon, 20)) : null, input),
      (p.error || p.hint) ? h("div", { id: id + "-h", className: p.error ? "ms-field-error" : "ms-field-hint" }, p.error || p.hint) : null);
  }

  function Chip(p) {
    return h("button", { type: "button", className: cx("ms-chip", p.selected && "ms-chip-on"), "aria-pressed": !!p.selected, onClick: p.onClick },
      p.selected ? Ic("check_circle", 18) : Ic(p.icon, 18), h("span", null, p.children), p.count != null ? h("span", { className: "ms-chip-count" }, p.count) : null);
  }

  var TONES = {
    CONFIRMED: ["green", "check_circle"], ISSUED: ["green", "check_circle"], PUBLISHED: ["green", "check_circle"], ACTIVE: ["green", "check_circle"], APPROVED: ["green", "verified"], VALID: ["green", "check_circle"], ALLOW: ["green", "verified"],
    PENDING: ["wheat", "schedule"], PENDING_PAYMENT: ["wheat", "schedule"], BOARDING: ["wheat", "schedule"], REVIEW: ["wheat", "warning"], DRAFT: ["neutral", "info"],
    DEPARTED: ["blue", "directions_bus"], IN_PROGRESS: ["blue", "my_location"], COMPLETED: ["blue", "check_circle"], BOARDED: ["blue", "check_circle"],
    CANCELLED: ["red", "error"], REJECTED: ["red", "error"], EXPIRED: ["red", "error"], DENY: ["red", "shield"], INVALID: ["red", "error"], SUSPENDED: ["red", "error"]
  };
  function StatusBadge(p) {
    var t = TONES[p.status] || [p.tone || "neutral", "info"];
    return h("span", { className: cx("ms-badge", "ms-badge-" + (p.tone || t[0])) }, Ic(t[1], 16), h("span", null, p.children || p.status));
  }

  function SegmentedButton(p) {
    var st = R.useState(p.value != null ? p.value : (p.options[0] || {}).value), val = st[0];
    return h("div", { className: "ms-seg", role: "radiogroup", "aria-label": p.label },
      p.options.map(function (o) {
        var on = o.value === val;
        return h("button", { key: o.value, type: "button", role: "radio", "aria-checked": on, className: cx("ms-seg-btn", on && "ms-seg-on"),
          onClick: function () { st[1](o.value); p.onChange && p.onChange(o.value); } }, on ? Ic("check_circle", 18) : Ic(o.icon, 18), h("span", null, o.label));
      }));
  }

  function Card(p) {
    return h("section", { className: cx("ms-card", "ms-card-" + (p.variant || "elevated"), p.className), style: p.style },
      (p.title || p.action) ? h("div", { className: "ms-card-head" }, h("h3", { className: "title-medium" }, p.title), p.action || null) : null,
      p.children);
  }

  function Stat(p) {
    return h("div", { className: cx("ms-stat", "ms-stat-" + (p.tone || "green")) },
      h("div", { className: "ms-stat-label" }, h("span", { className: "ms-stat-ic" }, Ic(p.icon, 20)), h("span", null, p.label)),
      h("div", { className: "ms-stat-value" }, p.value),
      p.note ? h("div", { className: "ms-stat-note" }, p.note) : null);
  }

  var BANNER_IC = { info: "info", success: "check_circle", warning: "warning", error: "error" };
  function Banner(p) {
    var tone = p.tone || "info";
    return h("div", { className: cx("ms-banner", "ms-banner-" + tone), role: tone === "error" ? "alert" : "status" },
      Ic(BANNER_IC[tone], 22),
      h("div", { className: "ms-banner-body" }, p.title ? h("b", null, p.title) : null, p.children ? h("div", null, p.children) : null),
      p.action || null);
  }

  function TopAppBar(p) {
    return h("header", { className: cx("ms-appbar", p.translucent && "ms-appbar-glass") },
      p.leading || null,
      h("div", { className: "ms-appbar-title" }, h("div", { className: "title-large" }, p.title), p.subtitle ? h("div", { className: "body-small ms-muted" }, p.subtitle) : null),
      h("div", { className: "ms-appbar-actions" }, p.actions || null));
  }

  function NavigationDrawer(p) {
    return h("nav", { className: "ms-drawer", "aria-label": p.label || "Main" },
      p.brand || null,
      (p.sections || []).map(function (s, i) {
        return h("div", { key: i, className: "ms-drawer-sec" },
          s.title ? h("div", { className: "ms-drawer-title" }, s.title) : null,
          s.items.map(function (it, j) {
            return h("a", { key: j, href: "#", className: cx("ms-nav-item", it.active && "ms-nav-on"), "aria-current": it.active ? "page" : undefined },
              Ic(it.icon, 22), h("span", null, it.label), it.badge ? h("span", { className: "ms-nav-badge" }, it.badge) : null);
          }));
      }),
      p.footer ? h("div", { className: "ms-drawer-foot" }, p.footer) : null);
  }

  function NavigationBar(p) {
    return h("nav", { className: "ms-navbar", "aria-label": p.label || "Main" },
      p.items.map(function (it, i) {
        return h("a", { key: i, href: "#", className: cx("ms-navbar-item", it.active && "ms-navbar-on"), "aria-current": it.active ? "page" : undefined },
          h("span", { className: "ms-navbar-pill" }, Ic(it.icon, 24), it.badge ? h("span", { className: "ms-dot" }) : null), h("span", null, it.label));
      }));
  }

  function TripCard(p) {
    return h("article", { className: "ms-trip" },
      h("div", { className: "ms-trip-main" },
        h("div", { className: "ms-trip-carrier" }, h("span", { className: "ms-trip-logo" }, Ic("directions_bus", 20)),
          h("div", null, h("div", { className: "title-small" }, p.carrier), h("div", { className: "body-small ms-muted" }, p.fareBrand))),
        h("div", { className: "ms-trip-line" },
          h("div", { className: "ms-trip-end" }, h("div", { className: "ms-trip-time" }, p.depart), h("div", { className: "body-small ms-muted" }, p.from)),
          h("div", { className: "ms-trip-track" }, h("span", { className: "body-small ms-muted" }, p.duration), h("i", null)),
          h("div", { className: "ms-trip-end" }, h("div", { className: "ms-trip-time" }, p.arrive), h("div", { className: "body-small ms-muted" }, p.to))),
        p.tags ? h("div", { className: "ms-trip-tags" }, p.tags.map(function (t, i) { return h("span", { key: i, className: "ms-tag" }, t); })) : null),
      h("div", { className: "ms-trip-side" },
        h("div", { className: "ms-price" }, p.price, h("small", null, " " + (p.currency || "ل.س"))),
        p.seatsLeft != null ? h("div", { className: cx("body-small", p.seatsLeft <= 5 ? "ms-warn-text" : "ms-muted") }, p.seatsLabel || ("متبقٍ " + p.seatsLeft + " مقاعد")) : null,
        p.action || null));
  }

  function StopTimeline(p) {
    return h("ol", { className: "ms-stops" }, p.stops.map(function (s, i) {
      return h("li", { key: i, className: cx("ms-stop", "ms-stop-" + (s.state || "next")) },
        h("span", { className: "ms-stop-dot" }),
        h("div", null, h("div", { className: "title-small" }, s.name), s.note ? h("div", { className: "body-small ms-muted" }, s.note) : null),
        h("div", { className: "ms-stop-time" }, s.time));
    }));
  }

  function SeatMap(p) {
    var sel = p.selected || [], taken = p.taken || [];
    var st = R.useState(sel), mine = st[0];
    function toggle(n) { st[1](mine.indexOf(n) >= 0 ? mine.filter(function (x) { return x !== n; }) : mine.concat([n])); }
    var rows = p.rows || 8, n = 0, cells = [];
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < 5; c++) {
        if (c === 2) { cells.push(h("span", { key: r + "a", className: "ms-aisle" })); continue; }
        n++;
        var num = n, isT = taken.indexOf(num) >= 0, isM = mine.indexOf(num) >= 0;
        cells.push(h("button", { key: r + "-" + c, type: "button", className: cx("ms-seat", isT && "ms-seat-taken", isM && "ms-seat-mine"), disabled: isT,
          "aria-pressed": isM, "aria-label": (p.seatWord || "مقعد") + " " + num, onClick: (function (k) { return function () { toggle(k); }; })(num) }, num));
      }
    }
    var L = p.legend || ["متاح", "محجوز", "اختيارك"];
    return h("div", { className: "ms-seatmap" },
      h("div", { className: "ms-bus", dir: "ltr" }, h("div", { className: "ms-bus-front" }, h("span", { className: "ms-wheel" }, Ic("directions_bus", 18)), h("span", null, p.frontLabel || "الأمام")),
        h("div", { className: "ms-seats" }, cells)),
      h("div", { className: "ms-legend" }, h("span", null, h("i", { className: "ms-lg-free" }), L[0]), h("span", null, h("i", { className: "ms-lg-taken" }), L[1]), h("span", null, h("i", { className: "ms-lg-mine" }), L[2])));
  }

  function fakeQR(seed) {
    var s = 0; for (var i = 0; i < seed.length; i++) s = (s * 31 + seed.charCodeAt(i)) >>> 0;
    var N = 25, rects = [];
    function finder(x, y) { rects.push(h("rect", { key: "f" + x + y, x: x, y: y, width: 7, height: 7, fill: "#0E1511" }), h("rect", { key: "g" + x + y, x: x + 1, y: y + 1, width: 5, height: 5, fill: "#FFFFFF" }), h("rect", { key: "k" + x + y, x: x + 2, y: y + 2, width: 3, height: 3, fill: "#0E1511" })); }
    for (var y = 0; y < N; y++) for (var x = 0; x < N; x++) {
      if ((x < 8 && y < 8) || (x > 16 && y < 8) || (x < 8 && y > 16)) continue;
      s = (s * 1103515245 + 12345) >>> 0;
      if ((s >>> 16) & 1) rects.push(h("rect", { key: x + "_" + y, x: x, y: y, width: 1, height: 1, fill: "#0E1511" }));
    }
    finder(0, 0); finder(18, 0); finder(0, 18);
    return h("svg", { viewBox: "-2 -2 29 29", width: 168, height: 168, role: "img", "aria-label": "QR" }, h("rect", { x: -2, y: -2, width: 29, height: 29, fill: "#FFFFFF" }), rects);
  }

  function Ticket(p) {
    var L = p.labels || { date: "التاريخ", time: "الانطلاق", seat: "المقعد", passenger: "المسافر", ref: "رقم الحجز" };
    return h("article", { className: "ms-ticket" },
      h("div", { className: "ms-ticket-top" },
        h("div", { className: "ms-ticket-carrier" }, h(Mark, { size: 32 }), h("span", { className: "ms-ticket-id" }, h("span", { className: "ms-ticket-kicker" }, p.kicker || "BOARDING PASS"), h("span", null, p.carrier)), p.status ? h(StatusBadge, { status: p.status }, p.statusLabel) : null),
        h("div", { className: "ms-ticket-route" }, h("div", null, h("div", { className: "ms-ticket-city" }, p.from), h("div", { className: "ms-ticket-sub" }, p.fromStation)),
          h("span", { className: "ms-ticket-arrow" }, h(Icon, { name: "arrow_back", size: 22, className: "ms-route-arrow" })),
          h("div", null, h("div", { className: "ms-ticket-city" }, p.to), h("div", { className: "ms-ticket-sub" }, p.toStation)))),
      h("div", { className: "ms-ticket-grid" },
        [[L.date, p.date], [L.time, p.time], [L.seat, p.seat], [L.passenger, p.passenger]].map(function (kv, i) {
          return h("div", { key: i }, h("div", { className: "label-medium ms-muted" }, kv[0]), h("div", { className: "title-medium" }, kv[1]));
        })),
      h("div", { className: "ms-ticket-cut" }),
      h("div", { className: "ms-ticket-qr" }, h("div", { className: "ms-qr" }, fakeQR(p.reference || "x")),
        h("div", { className: "label-medium ms-muted" }, L.ref), h("div", { className: "data-large", dir: "ltr" }, p.reference),
        p.offline ? h("div", { className: "ms-offline" }, Ic("check_circle", 16), h("span", null, p.offline)) : null));
  }

  function DataTable(p) {
    return h("div", { className: "ms-table-wrap" }, h("table", { className: "ms-table" },
      h("thead", null, h("tr", null, p.columns.map(function (c) { return h("th", { key: c.key, className: c.align === "end" ? "ms-end" : undefined }, c.label); }))),
      h("tbody", null, p.rows.map(function (r, i) {
        return h("tr", { key: i }, p.columns.map(function (c) {
          var v = r[c.key];
          if (c.status) v = h(StatusBadge, { status: v.status || v }, v.label);
          return h("td", { key: c.key, className: cx(c.align === "end" && "ms-end", c.mono && "ms-mono") }, v);
        }));
      }))));
  }

  function Dialog(p) {
    return h("div", { className: cx("ms-dialog-scrim", p.inline && "ms-inline") },
      h("div", { className: "ms-dialog", role: "dialog", "aria-modal": "true", "aria-label": p.title },
        p.icon ? h("div", { className: "ms-dialog-ic" }, Ic(p.icon, 26)) : null,
        h("h2", { className: "headline-small" }, p.title),
        h("div", { className: "body-medium ms-muted ms-dialog-body" }, p.children),
        h("div", { className: "ms-dialog-actions" }, p.actions)));
  }

  function Snackbar(p) {
    return h("div", { className: "ms-snack", role: "status" }, h("span", null, p.message), p.action ? h("button", { type: "button", className: "ms-snack-action" }, p.action) : null);
  }

  var C = window;
  C.Masslak = Object.assign(C.Masslak || {}, { Icon: Icon, Logo: Logo, Mark: Mark, Button: Button, IconButton: IconButton, TextField: TextField, Chip: Chip, StatusBadge: StatusBadge,
    SegmentedButton: SegmentedButton, Card: Card, Stat: Stat, Banner: Banner, TopAppBar: TopAppBar, NavigationDrawer: NavigationDrawer, NavigationBar: NavigationBar,
    TripCard: TripCard, StopTimeline: StopTimeline, SeatMap: SeatMap, Ticket: Ticket, DataTable: DataTable, Dialog: Dialog, Snackbar: Snackbar, ICONS: ICONS });
})();
