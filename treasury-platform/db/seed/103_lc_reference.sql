/* ============================================================================
   BankFas - 103: letter-of-credit reference data of the platform (DOC-B05 section 4.1)
     ref.Incoterm      the 11 Incoterms 2020 rules and the 5 earlier ones as LEGACY (FR-CAT-021, BR-CAT-015,
                       FR-LCT-013, BR-LCT-010; 11-m2-m4 section 6.4). LEGACY terms are shown on old letters of credit and
                       cannot be chosen on new ones. IsSeaOnly marks the sea and inland waterway terms (a warning with
                       another transport mode, V-LCT-08); RequiresInsurance marks CIF and CIP.
     ref.UcpArticle    the 39 articles of UCP 600 as platform rows (TenantId NULL), all UNVERIFIED (FR-LCT-006,
                       BR-LCT-018). TopicAr is the topic of the article map in docs/02-forms-analysis-ucp600.md section 3.

   The codes and the English names follow ICC usage. The Arabic names and titles are working translations for the
   treasury manager to confirm, and the article titles and numbers are engineering references until a specialist checks
   them against ICC Publication 600 and a platform operator records the check (O-06, Q-LCT-01): until then every
   article stays UNVERIFIED, which shows the badge and the print footnote.

   Insert only: a row that exists is never changed, so an operator's correction or verification stays (FR-CAT-026).
   ref.UcpArticle has a row filter that lets only tp_platform write platform rows, so its block runs as a temporary
   user of that role, removed at the end.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
MERGE ref.Incoterm AS d
USING (VALUES
    ('EXW', N'Ex Works',                           N'التسليم في موقع البائع',               '2020', 'ACTIVE', 0, 0, 1),
    ('FCA', N'Free Carrier',                       N'التسليم إلى الناقل',                   '2020', 'ACTIVE', 0, 0, 2),
    ('CPT', N'Carriage Paid To',                   N'أجرة النقل مدفوعة إلى',                '2020', 'ACTIVE', 0, 0, 3),
    ('CIP', N'Carriage and Insurance Paid To',     N'أجرة النقل والتأمين مدفوعان إلى',      '2020', 'ACTIVE', 0, 1, 4),
    ('DAP', N'Delivered at Place',                 N'التسليم في المكان',                    '2020', 'ACTIVE', 0, 0, 5),
    ('DPU', N'Delivered at Place Unloaded',        N'التسليم في المكان بعد التفريغ',        '2020', 'ACTIVE', 0, 0, 6),
    ('DDP', N'Delivered Duty Paid',                N'التسليم مع دفع الرسوم الجمركية',       '2020', 'ACTIVE', 0, 0, 7),
    ('FAS', N'Free Alongside Ship',                N'التسليم بجانب السفينة',                '2020', 'ACTIVE', 1, 0, 8),
    ('FOB', N'Free on Board',                      N'التسليم على ظهر السفينة',              '2020', 'ACTIVE', 1, 0, 9),
    ('CFR', N'Cost and Freight',                   N'التكلفة وأجرة الشحن',                  '2020', 'ACTIVE', 1, 0, 10),
    ('CIF', N'Cost, Insurance and Freight',        N'التكلفة والتأمين وأجرة الشحن',         '2020', 'ACTIVE', 1, 1, 11),
    ('DAT', N'Delivered at Terminal',              N'التسليم في المحطة',                    '2010', 'LEGACY', 0, 0, 101),
    ('DAF', N'Delivered at Frontier',              N'التسليم على الحدود',                   '2000', 'LEGACY', 0, 0, 102),
    ('DES', N'Delivered Ex Ship',                  N'التسليم من السفينة',                   '2000', 'LEGACY', 1, 0, 103),
    ('DEQ', N'Delivered Ex Quay',                  N'التسليم على الرصيف',                   '2000', 'LEGACY', 1, 0, 104),
    ('DDU', N'Delivered Duty Unpaid',              N'التسليم دون دفع الرسوم الجمركية',      '2000', 'LEGACY', 0, 0, 105)
) AS s (Code, NameEn, NameAr, RulesVersion, Status, IsSeaOnly, RequiresInsurance, SortOrder)
   ON d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, NameEn, NameAr, RulesVersion, Status, IsSeaOnly, RequiresInsurance, SortOrder)
    VALUES (s.Code, s.NameEn, s.NameAr, s.RulesVersion, s.Status, s.IsSeaOnly, s.RequiresInsurance, s.SortOrder);
GO
IF USER_ID(N'tp_seed_platform') IS NULL
BEGIN
    CREATE USER [tp_seed_platform] WITHOUT LOGIN;
    ALTER ROLE [tp_platform] ADD MEMBER [tp_seed_platform];
END;
GO
EXECUTE AS USER = N'tp_seed_platform';
MERGE ref.UcpArticle AS d
USING (VALUES
    ('1',  N'Application of UCP', N'تطبيق القواعد', N'نطاق التطبيق'),
    ('2',  N'Definitions', N'التعريفات', N'التعريفات: الطالب، المستفيد، المبلّغ، المعزِّز، الوفاء، التداول'),
    ('3',  N'Interpretations', N'التفسيرات', N'التفسيرات: «حوالي»، «من»، «بعد»، «حتى»'),
    ('4',  N'Credits v. Contracts', N'الاعتمادات مقابل العقود', N'استقلال الاعتماد عن العقد'),
    ('5',  N'Documents v. Goods, Services or Performance', N'المستندات مقابل البضائع أو الخدمات أو الأداء', N'التعامل بالمستندات لا بالبضاعة'),
    ('6',  N'Availability, Expiry Date and Place for Presentation', N'الإتاحة وتاريخ الانتهاء ومكان التقديم', N'الإتاحة، تاريخ الانتهاء، مكان التقديم'),
    ('7',  N'Issuing Bank Undertaking', N'تعهد البنك المُصدِر', N'التزام البنك المُصدِر'),
    ('8',  N'Confirming Bank Undertaking', N'تعهد البنك المعزِّز', N'التزام البنك المعزِّز'),
    ('9',  N'Advising of Credits and Amendments', N'تبليغ الاعتمادات والتعديلات', N'التبليغ'),
    ('10', N'Amendments', N'التعديلات', N'التعديلات'),
    ('11', N'Teletransmitted and Pre-Advised Credits and Amendments', N'الاعتمادات والتعديلات المرسلة إلكترونيًا والمبلَّغة مسبقًا', NULL),
    ('12', N'Nomination', N'التعيين', N'التعيين'),
    ('13', N'Bank-to-Bank Reimbursement Arrangements', N'ترتيبات التغطية بين البنوك', NULL),
    ('14', N'Standard for Examination of Documents', N'معيار فحص المستندات', N'معيار فحص المستندات (14-ج: 21 يومًا)'),
    ('15', N'Complying Presentation', N'التقديم المطابق', N'مطابقة التقديم'),
    ('16', N'Discrepant Documents, Waiver and Notice', N'المستندات المخالفة والتنازل والإخطار', N'المخالفات والإخطار'),
    ('17', N'Original Documents and Copies', N'المستندات الأصلية والنسخ', N'الأصول والنسخ'),
    ('18', N'Commercial Invoice', N'الفاتورة التجارية', N'الفاتورة التجارية'),
    ('19', N'Transport Document Covering at Least Two Different Modes of Transport', N'مستند نقل يغطي وسيلتي نقل مختلفتين على الأقل', N'النقل المتعدد الوسائط'),
    ('20', N'Bill of Lading', N'سند الشحن البحري', N'سند الشحن البحري'),
    ('21', N'Non-Negotiable Sea Waybill', N'بوليصة الشحن البحري غير القابلة للتداول', N'بوليصة بحرية غير قابلة للتداول'),
    ('22', N'Charter Party Bill of Lading', N'سند شحن بموجب مشارطة إيجار', N'سند شحن المشارطة'),
    ('23', N'Air Transport Document', N'مستند النقل الجوي', N'النقل الجوي'),
    ('24', N'Road, Rail or Inland Waterway Transport Documents', N'مستندات النقل البري أو بالسكك الحديدية أو بالممرات المائية الداخلية', N'النقل البري/السكك/الممرات المائية'),
    ('25', N'Courier Receipt, Post Receipt or Certificate of Posting', N'إيصال البريد السريع أو إيصال البريد أو شهادة الإرسال بالبريد', N'البريد السريع'),
    ('26', N'"On Deck", "Shipper''s Load and Count", "Said by Shipper to Contain" and Charges Additional to Freight', N'«على ظهر السفينة» و«تحميل الشاحن وعدّه» و«حسب قول الشاحن» والرسوم الإضافية على أجرة الشحن', N'«على ظهر السفينة» والرسوم الإضافية'),
    ('27', N'Clean Transport Document', N'مستند النقل النظيف', N'مستند نقل نظيف'),
    ('28', N'Insurance Document and Coverage', N'مستند التأمين والتغطية', N'التأمين (110%)'),
    ('29', N'Extension of Expiry Date or Last Day for Presentation', N'تمديد تاريخ الانتهاء أو آخر يوم للتقديم', N'تمديد الانتهاء'),
    ('30', N'Tolerance in Credit Amount, Quantity and Unit Prices', N'التسامح في مبلغ الاعتماد والكمية وأسعار الوحدات', N'التسامح'),
    ('31', N'Partial Drawings or Shipments', N'السحوبات أو الشحنات الجزئية', N'الشحن الجزئي'),
    ('32', N'Instalment Drawings or Shipments', N'السحوبات أو الشحنات على دفعات', N'الشحن على دفعات'),
    ('33', N'Hours of Presentation', N'ساعات التقديم', N'ساعات التقديم'),
    ('34', N'Disclaimer on Effectiveness of Documents', N'إخلاء المسؤولية عن فعالية المستندات', NULL),
    ('35', N'Disclaimer on Transmission and Translation', N'إخلاء المسؤولية عن الإرسال والترجمة', NULL),
    ('36', N'Force Majeure', N'القوة القاهرة', N'القوة القاهرة'),
    ('37', N'Disclaimer for Acts of an Instructed Party', N'إخلاء المسؤولية عن أفعال الطرف المكلَّف', N'الرسوم وأفعال الأطراف المكلَّفة'),
    ('38', N'Transferable Credits', N'الاعتمادات القابلة للتحويل', N'الاعتماد القابل للتحويل'),
    ('39', N'Assignment of Proceeds', N'التنازل عن العائدات', N'التنازل عن العائدات')
) AS s (ArticleNo, TitleEn, TitleAr, TopicAr)
   ON d.TenantId IS NULL AND d.Version = 'UCP600' AND d.ArticleNo = s.ArticleNo
WHEN NOT MATCHED THEN
    INSERT (TenantId, Version, ArticleNo, TitleAr, TitleEn, TopicAr, VerificationStatus, SeedKey)
    VALUES (NULL, 'UCP600', s.ArticleNo, s.TitleAr, s.TitleEn, s.TopicAr, 'UNVERIFIED', CONCAT('UCP600-', RIGHT(CONCAT('0', s.ArticleNo), 2)));
REVERT;
GO
DROP USER [tp_seed_platform];
GO
