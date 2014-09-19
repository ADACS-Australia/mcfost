module dust_transfer

  use parametres
  use disk
  use grains
  use naleat, only : seed, stream, gtype
  use resultats
  use opacity
  use em_th
  use prop_star
  use constantes
  use wall
  use ray_tracing
  use scattering
  use grid
  use optical_depth
  use density
  use PAH
  use thermal_emission
  use disk_physics
  use output
  use input
  use benchmarks
  use diffusion
  use dust
  use stars
  use mem
  use utils
  use ProDiMo
  use init_mcfost
  !$ use omp_lib

  implicit none

  contains

subroutine transfert_poussiere()

  implicit none

#include "sprng_f.h"

  ! Energie des paquets
  real(kind=db), dimension(4) :: Stokes, Stokes_old


  ! Parametres simu
  integer :: time, lambda_seuil, ymap0, xmap0, ndifus, nbre_phot2, sig, signal
  integer :: n_dif_max, nbr_arg, i_arg, ind_etape, first_etape_obs
  real ::  delta_time, cpu_time_begin, cpu_time_end
  integer :: etape_start, nnfot1_start, n_iter, iTrans, ibin

  real :: n_phot_lim
  logical :: lpacket_alive, lintersect

  logical :: lscatt_ray_tracing1_save, lscatt_ray_tracing2_save

  ! NEW
  integer, target :: lambda, lambda0
  integer, pointer, save :: p_lambda

  real(kind=db) :: x,y,z, u,v,w
  real :: rand
  integer :: i, ri, zj, phik
  logical :: flag_star, flag_scatt


  logical :: laffichage, flag_em_nRE, lcompute_dust_prop

  ! Param�tres parallelisation
  integer :: id=1

  real(kind=db), dimension(:), pointer :: p_nnfot2


  ! Energie des paquets mise a 1
  E_paquet = 1.0_db

  ! Nbre iteration grains hors equilibre
  n_iter = 0

  ! parametrage methode de diffusion
  if (scattering_method == 0) then
     if ((lstrat).and.(.not.lmono).and.(.not.lscatt_ray_tracing)) then
        scattering_method = 1
     else
        scattering_method = 2
     endif
  endif
  lscattering_method1 = (scattering_method==1)
  if (lscattering_method1) then
     lambda = 1
     p_lambda => lambda
 else
     lambda0=1
     p_lambda => lambda ! was lambda0 : changed to save dust properties
  endif


  if (lstrat) then
     p_n_rad=n_rad ; p_nz = nz
  else
     p_n_rad=1 ;  p_nz=1
  endif

  if (l3D) then
     j_start = -nz
     if (lstrat) then
        p_n_az = n_az
     else
        p_n_az = 1
     endif
  else
     j_start = 1
     p_n_az = 1
  endif

  if ((p_nz /= 1).and.l3D) then
     pj_start = -nz
  else
     pj_start = 1
  endif


  ! Allocation dynamique
  call alloc_dynamique()
  allocate(p_nnfot2(nb_proc))

  ymap0 = (igridy/2) + 1
  xmap0 = (igridx/2) + 1

  ! Pour rotation du disque (signe - pour convention astro)
  cos_disk = cos(ang_disque/180.*pi)
  sin_disk = -sin(ang_disque/180.*pi)

  laffichage=.true.

  stream = 0.0
  do i=1, nb_proc
     stream(i) = init_sprng(gtype, i-1,nb_proc,seed,SPRNG_DEFAULT)
  enddo


  call init_lambda()
  call init_indices_optiques()

  call taille_grains()

  if (lold_grid) then
     call define_grid3()
  else
     call order_zones()
     call define_physical_zones()
     call define_grid4()
  endif

  if (lProDiMo) call setup_ProDiMo()

  !call densite_data_hd32297(para) ! grille redefinie dans routine
  if (ldensity_file) then
     call densite_file()
  elseif (lgap) then
     call densite_data_gap
  else if (lstrat_SPH) then
     call densite_data_SPH_TTauri_2
  else if (lstrat_SPH_bin) then
     call densite_data_SPH_binaire
  else if (lfits) then
     call densite_fits
  else if (ldebris) then
     call densite_debris
  else if (lLaure_SED) then
     call densite_data_LAURE_SED()
  else if (lread_Seb_Charnoz) then
     call densite_Seb_Charnoz()
  else if (lread_Seb_Charnoz2) then
     call densite_Seb_Charnoz2()
  else
     call define_density()
  endif

  if (lwall) call define_density_wall3D()

  if (ldisk_struct) call write_disk_struct()

  if (lmono) then ! code monochromatique
     lambda=1
     etape_i=1
     etape_f=1
     letape_th = .false.
     first_etape_obs=1

     n_phot_lim=1.0e30

     if (aniso_method==1) then
        lmethod_aniso1=.true.
     else
        lmethod_aniso1=.false.
        if (laggregate) then
           write(*,*) "Error : you must use scattering method 1 when grains are aggregates"
           stop
        endif
     endif
     call repartition_energie_etoiles()
     call prop_grains(1,1)
     if (lscatt_ray_tracing) then
        call alloc_ray_tracing()
        call init_directions_ray_tracing()
     endif
     call opacite2(1)
     call integ_tau(1) !TODO

     if (loptical_depth_map) call calc_optical_depth_map(1)

     write(*,*) ""
     write(*,*) "Dust properties in cell (1,1,1): "
     write(*,*) "g             ", tab_g_pos(1,1,1,1)
     write(*,*) "albedo        ", tab_albedo_pos(1,1,1,1)
     if (lsepar_pola) write(*,*) "polarisability", maxval(-tab_s12_pos(1,1,1,1,:)/tab_s11_pos(1,1,1,1,:))

     if (lopacite_only) stop

     if (l_em_disk_image) then ! le disque �met
        call lect_Temperature()
     else ! Seule l'�toile �met
        Temperature=0.0
     endif !l_em_disk_image

  else ! not lmono

     if (aniso_method==1) then
        lmethod_aniso1 = .true.
     else
        lmethod_aniso1 = .false.
     endif

     first_etape_obs=2
     ! Nbre d'�tapes � d�terminer pour code thermique
     if (ltemp) then
        etape_i=1
        letape_th=.true.
     else
        etape_i=2
        letape_th=.false.
        call lect_Temperature()
     endif
     if (lsed) then
        if (lsed_complete) then
           etape_f=1+n_lambda
           n_lambda2 = n_lambda
        else
           etape_f=1+n_lambda2 ! modif nombre �tape
        endif
     else
        etape_f=1
     endif


     if (ltemp.or.lsed_complete) then
        frac_E_stars=1.0 ! dans phase1 tous les photons partent de l'etoile
        call repartition_energie_etoiles()

        if (.not.lbenchmark_Pascucci) then
           if (lscatt_ray_tracing.and.lsed_complete) then
              call alloc_ray_tracing()
              call init_directions_ray_tracing()
           endif

           ! Try to restore dust calculation from previous run
           call read_saved_dust_prop(letape_th, lcompute_dust_prop)
           if (lcompute_dust_prop) then
              write(*,'(a30, $)') "Computing dust properties ..."
           else
              write(*,'(a46, $)') "Reading dust properties from previous run ..."
           endif
           do lambda=1,n_lambda
              if (lcompute_dust_prop) call prop_grains(lambda, p_lambda)
              call opacite2(lambda)!_eqdiff!_data  ! ~ takes 2 seconds
           enddo !n
           if (lcompute_dust_prop) call save_dust_prop(letape_th)
           write(*,*) "Done"

           if (ldust_sublimation)  then
              call compute_othin_sublimation_radius()
              call define_grid4()
              call define_dust_density()

              do lambda=1,n_lambda
                 ! recalcul pour opacite 2 :peut etre eviter mais implique + meme : garder tab_s11 en mem
                 call prop_grains(lambda, p_lambda)
                 call opacite2(lambda)
              enddo
           endif ! ldust_sublimation

           test_tau : do lambda=1,n_lambda
              if (tab_lambda(lambda) > wl_seuil) then
                 lambda_seuil=lambda
                 exit test_tau
              endif
           enddo test_tau
           write(*,*) "lambda =", tab_lambda(lambda_seuil)
           call integ_tau(lambda_seuil)
           if (loptical_depth_map) call calc_optical_depth_map(lambda_seuil)

           if (lspherical.or.l3D) then
              write(*,*) "No dark zone"
              call no_dark_zone()
              lapprox_diffusion=.false.
           else
              if (lapprox_diffusion) then
                 call define_dark_zone(lambda_seuil,tau_dark_zone_eq_th,.true.) ! BUG avec 1 cellule
              else
                 write(*,*) "No dark zone"
                 call no_dark_zone()
              endif
           endif

           if (lonly_diff_approx) then
              call lect_temperature()
              call Temp_approx_diffusion_vertical()
              ! call Temp_approx_diffusion()
              call ecriture_temperature(2)
              return
           endif

        else ! Benchmark Pascucci: ne marche qu'avec le mode 2-2 pour le scattering
           frac_E_stars=1.0
           call lect_section_eff
           call repartition_energie_etoiles
           if (lcylindrical) call integ_tau(15) !TODO
        endif ! Fin bench

        if (ltemp) then
           call init_reemission()
           call chauffage_interne()
        endif

        !$omp parallel default(none) private(lambda) shared(n_lambda)
        !$omp do schedule(static,1)
        do lambda=1, n_lambda
           call repartition_energie(lambda)
        enddo
        !$omp end do
        !$omp end parallel

        call repartition_wl_em()

        if (lnRE) call init_emissivite_nRE()

     endif ! ltemp.or.lsed_complete

  endif ! lmono

  if (laverage_grain_size) call taille_moyenne_grains()

  ! Calcul de l'angle maximal d'ouverture du disque : TODO : revoir ce bout !!
  call angle_disque()

  if (lopacity_wall) call init_opacity_wall()
  if (lwall) cos_max2 = 0.0

  if (lcylindrical) call angle_max(1) ! TODO
  if (lspherical) cos_max2=0.0

  etape_start=etape_i
  nnfot1_start=1
  lambda=1 ! pour eviter depassement tab a l'initialisation
  ind_etape = etape_start

  ! Boucle principale sur les �tapes du calcul
  do while (ind_etape <= etape_f)
     indice_etape=ind_etape


     if (letape_th) then ! Calcul des temperatures
        nbre_phot2 = nbre_photons_eq_th
        n_phot_lim = 1.0e30 ! on ne tue pas les paquets
     else ! calcul des observables
        ! on devient monochromatique
        lmono=.true.

        E_paquet = 1.0_db

        if (lmono0) then ! image
           laffichage=.true.
           nbre_phot2 = nbre_photons_image
           n_phot_lim = 1.0e30 ! On ne limite pas le nbre de photons
        else ! SED
           lambda=1
           laffichage=.false.
           nbre_phot2 = nbre_photons_lambda
           n_phot_lim = nbre_photons_lim
        endif

        if ((ind_etape==first_etape_obs).and.lremove) then
           call remove_specie
           if (ltemp.and.lsed_complete) then
              write(*,'(a30, $)') "Computing dust properties ..."
              do lambda=1, n_lambda
                 call prop_grains(lambda, p_lambda) ! recalcul pour opacite2
                 call opacite2(lambda)
              enddo
              write(*,*) "Done"
           endif
        endif

        if ((ind_etape==first_etape_obs).and.(.not.lsed_complete).and.(.not.lmono0)) then ! Changement des lambda
           call init_lambda2()
           call init_indices_optiques()

           call repartition_energie_etoiles()

           if (lscatt_ray_tracing) then
              call alloc_ray_tracing()
              call init_directions_ray_tracing()
           endif

           ! Recalcul des propri�t�s optiques
           ! Try to restore dust calculation from previous run
           call read_saved_dust_prop(letape_th, lcompute_dust_prop)
           if (lcompute_dust_prop) then
              write(*,'(a30, $)') "Computing dust properties ..."
           else
              write(*,'(a46, $)') "Reading dust properties from previous run ..."
           endif
           do lambda=1,n_lambda2
              if (lcompute_dust_prop) call prop_grains(lambda, p_lambda)
              call opacite2(lambda)!_eqdiff!_data  ! ~ takes 2 seconds
           enddo !n
           if (lcompute_dust_prop) call save_dust_prop(letape_th)
           write(*,*) "Done"
        endif
        lambda = ind_etape - first_etape_obs + 1

        if (lspherical.or.l3D) then
           call no_dark_zone()
        else
           call define_dark_zone(lambda,tau_dark_zone_obs,.false.)
        endif
        !call no_dark_zone()
        ! n_dif_max = seuil_n_dif(lambda)

        if (lweight_emission) call define_proba_weight_emission(lambda)

        call repartition_energie(lambda)
        if (lmono0) write(*,*) "frac. energy emitted by star : ", frac_E_stars(1)

     endif !letape_th

     if (ind_etape==etape_start) then
        call system_clock(time_end)

        time=int((time_end - time_begin)/time_tick)
        write (*,'(" Initialization complete in ", I3, "h", I3, "m", I3, "s")')  time/3600, mod(time/60,60), mod(time,60)
     endif

     if ((ind_etape >= first_etape_obs).and.(.not.lmono0)) then
        write(*,*) tab_lambda(lambda) ,frac_E_stars(lambda)
     endif

     ! Les pointeurs (meme les tab) doivent �tre priv�s !!! COPYIN
     !$omp parallel &
     !$omp default(none) &
     !$omp firstprivate(lambda) &
     !$omp private(id,ri,zj,phik,lpacket_alive,lintersect,p_nnfot2,rand) &
     !$omp private(x,y,z,u,v,w,Stokes,flag_star,flag_scatt) &
     !$omp shared(nnfot1_start,nbre_photons_loop,capt_sup,n_phot_lim,lscatt_ray_tracing1) &
     !$omp shared(n_phot_sed2,n_phot_envoyes,n_phot_envoyes_loc,nbre_phot2,nnfot2,lforce_1st_scatt) &
     !$omp shared(stream,laffichage,lmono,lmono0,lProDiMo,letape_th,tab_lambda,nbre_photons_lambda) &
     !$omp reduction(+:E_abs_nRE)

     if (letape_th) then
        p_nnfot2 => nnfot2
        E_abs_nRE = 0.0
     else
        if (lmono0) then
           p_nnfot2 => nnfot2
        else
           p_nnfot2 => n_phot_sed2(:,lambda,capt_sup,1)

           if (lProDiMo)  then
              p_nnfot2 => nnfot2  ! Nbre de paquet cst par lambda
              nbre_phot2 = nbre_photons_lambda * 10
              ! Augmentation du nbre de paquets dans UV
              if (tab_lambda(lambda) < 0.5) nbre_phot2 = nbre_photons_lambda * 10
           endif
        endif
     endif

     id = 1 ! Pour code sequentiel
     !$ id = omp_get_thread_num() + 1

     !$omp do schedule(dynamic,1)
     do nnfot1=nnfot1_start,nbre_photons_loop
        if (laffichage) write (*,*) nnfot1,'/',nbre_photons_loop, id
        p_nnfot2(id) = 0
        n_phot_envoyes_loc(lambda,id) = 0.0
        photon : do while ((p_nnfot2(id) < nbre_phot2).and.(n_phot_envoyes_loc(lambda,id) < n_phot_lim))
           nnfot2(id)=nnfot2(id)+1.0_db
           n_phot_envoyes(lambda,id) = n_phot_envoyes(lambda,id) + 1.0_db
           n_phot_envoyes_loc(lambda,id) = n_phot_envoyes_loc(lambda,id) + 1.0_db

           ! Choix longueur d'onde
           if (.not.lmono) then
              rand = sprng(stream(id))
              call select_wl_em(rand,lambda)
           endif

           ! Emission du paquet
           call emit_packet(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star)

           ! Propagation du packet
           if (lforce_1st_scatt) then
              call force_1st_scatt(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)
              if (lpacket_alive) call propagate_packet(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)
           else
              call propagate_packet(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)
           endif

           ! La paquet est maintenant sorti : on le met dans le bon capteur
           if (lpacket_alive) call capteur(id,lambda,ri,zj,x,y,z,u,v,w,Stokes,flag_star,flag_scatt)

        enddo photon !nnfot2
     enddo !nnfot1
     !$omp end do
     !$omp end parallel


     ! Champ de radiation interstellaire
     if ((.not.letape_th).and.lProDiMo) then
        ! Pas de ray-tracing avec les packets ISM
        lscatt_ray_tracing1_save = lscatt_ray_tracing1
        lscatt_ray_tracing2_save = lscatt_ray_tracing2
        lscatt_ray_tracing1 = .false.
        lscatt_ray_tracing2 = .false.

        ! Sauvegarde champ stellaire et th separement
        call save_J_ProDiMo(lambda)

        !$omp parallel &
        !$omp default(none) &
        !$omp shared(lambda,nnfot2,nbre_photons_lambda,nbre_photons_loop,n_phot_envoyes_ISM) &
        !$omp private(id, flag_star,flag_scatt,nnfot1,x,y,z,u,v,w,stokes,lintersect,ri,zj,phik,lpacket_alive)

        flag_star = .false.
        phik=1

        !$omp do schedule(dynamic,1)
        do nnfot1=1,nbre_photons_loop
           !$ id = omp_get_thread_num() + 1
           nnfot2(id) = 0.0_db
           photon_ISM : do while (nnfot2(id) < nbre_photons_lambda)
              n_phot_envoyes_ISM(lambda,id) = n_phot_envoyes_ISM(lambda,id) + 1.0_db

              ! Emission du paquet
              call emit_packet_ISM(id,ri,zj,x,y,z,u,v,w,stokes,lintersect)

              ! Le photon sert a quelquechose ou pas ??
              if (.not.lintersect) then
                 cycle photon_ISM
              else
                 nnfot2(id) = nnfot2(id) + 1.0_db
                 ! Propagation du packet
                 call propagate_packet(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)
              endif
           enddo photon_ISM ! nnfot2
        enddo ! nnfot1
        !$omp end do
        !$omp end parallel

        lscatt_ray_tracing1 = lscatt_ray_tracing1_save
        lscatt_ray_tracing2 = lscatt_ray_tracing2_save

     endif ! champ ISM

     !----------------------------------------------------
     if (lmono0) then ! Creation image
        if (loutput_mc) call write_stokes_fits()

        ! Carte ray-tracing
        if (lscatt_ray_tracing) then

           call system_clock(time_end)
           time=int((time_end - time_begin)/time_tick)
           write (*,'("Time = ", I3, "h", I3, "m", I3, "s")')  time/3600, mod(time/60,60), mod(time,60)

           do ibin=1,RT_n_ibin
              if (lscatt_ray_tracing1) then
                 call init_dust_source_fct1(lambda,ibin)
              else
                 call init_dust_source_fct2(lambda,ibin)
              endif
              call dust_map(lambda,ibin) ! Ne prend pas de temps en SED

              call system_clock(time_end)
              time=int((time_end - time_begin)/time_tick)
              write (*,'("Time = ", I3, "h", I3, "m", I3, "s")')  time/3600, mod(time/60,60), mod(time,60)
           enddo

           call ecriture_map_ray_tracing()
        endif

     elseif (letape_th) then ! Calcul de la structure en temperature

        letape_th=.false. ! A priori, on a calcule la temperature
        if (lRE_LTE) then
           call Temp_finale()
           if (lforce_T_Laure_SED)call force_T_Laure_SED()
           if (lreemission_stats) call reemission_stats()
        end if
        if (lRE_nLTE) then
           call Temp_finale_nLTE()
        endif
        if (lnRE) then
           call Temp_nRE(flag_em_nRE)
           if (n_iter > 10) then
              flag_em_nRE = .true.
              write(*,*) "WARNING: Reaching the maximum number of iterations"
              write(*,*) "radiation field may not be converged"
           endif

           if (.not.flag_em_nRE) then ! il faut iterer
              call emission_nRE()
              letape_th=.true.
              first_etape_obs = first_etape_obs + 1
              etape_f = etape_f + 1
              n_iter = n_iter + 1
              write(*,*) "Starting iteration", n_iter
           endif
        endif

        if (ldust_sublimation) then
           call sublimate_dust()
        endif

        ! A-t-on fini le calcul des grains hors eq ?
        if (.not.letape_th) then ! oui, on passe a la suite
           if (loutput_J) call ecriture_J()
           if (loutput_UV_field) call ecriture_UV_field()

           call ecriture_temperature(1)
           call ecriture_sed(1)

           if (lapprox_diffusion.and.l_is_dark_zone.and.(lemission_mol.or.lprodimo.or.lforce_diff_approx)) then
              call Temp_approx_diffusion_vertical()
             ! call Temp_approx_diffusion()
              call ecriture_temperature(2)
           endif

           ! Remise a zero pour etape suivante
           sed=0.0; sed_q=0.0 ; sed_u=0.0 ; sed_v=0.0
           n_phot_sed=0.0;  n_phot_sed2=0.0; n_phot_envoyes=0.0
           sed_star=0.0 ; sed_star_scat=0.0 ; sed_disk=0.0 ; sed_disk_scat=0.0
           if (lProDiMo) xJ_abs = 0.0  ! Au cas ou
        endif ! .not.letape_th


        call system_clock(time_end)
        if (time_end < time_begin) then
           time=int((time_end + (1.0 * time_max)- time_begin)/time_tick)
        else
           time=int((time_end - time_begin)/time_tick)
        endif
        write (*,'(" Temperature calculation complete in ", I3, "h", I3, "m", I3, "s")')  time/3600, mod(time/60,60), mod(time,60)

     else ! Etape 2 SED

        ! SED ray-tracing
        if (lscatt_ray_tracing) then
           do ibin=1,RT_n_ibin
              if (lscatt_ray_tracing1) then
                 call init_dust_source_fct1(lambda,ibin)
              else
                 call init_dust_source_fct2(lambda,ibin)
              endif
              call dust_map(lambda,ibin)
           enddo

           ! Pour longeur d'onde suivante
           if (lscatt_ray_tracing1) then
              xI_scatt = 0.0_db
           else
              xI = 0.0_db ; xI_star = 0.0_db ; xw_star = 0.0_db
           endif
        endif

        if (ind_etape==etape_f) then ! Ecriture SED ou spectre
           call ecriture_sed(2)
           if (lscatt_ray_tracing) call ecriture_sed_ray_tracing()
           if (lProDiMo) call mcfost2ProDiMo()
        endif

     endif

     ind_etape = ind_etape + 1
  enddo ! nbre_etapes

  return

end subroutine transfert_poussiere

!***********************************************************

subroutine emit_packet(id,lambda,ri,zj,phik,x0,y0,z0,u0,v0,w0,stokes,flag_star)
  ! C. Pinte
  ! 27/05/09

  integer, intent(in) :: id, lambda

  ! Position et direction du packet
  integer, intent(out) :: ri, zj, phik
  real(kind=db), intent(out) :: x0,y0,z0,u0,v0,w0
  real(kind=db), dimension(4), intent(out) :: Stokes

  ! Proprietes du packet
  logical, intent(out) :: flag_star
  real :: rand, rand2, rand3, rand4
  integer :: i_star

  real(kind=db) :: w02, phi, srw02
  real :: argmt

  ! Spot
  real, parameter :: T_spot = 9000.
  real, parameter :: surf_fraction_spot = 0.07
  real, parameter :: theta_spot = 25.
  real, parameter :: phi_spot = 0.
  real :: hc_lk, correct_spot, cos_thet_spot, x_spot, y_spot, z_spot



  ! TODO : flag_scat et flag_direct_star, id en argument ??

  rand = sprng(stream(id))
  if (rand <= frac_E_stars(lambda)) then ! Emission depuis �toile
     flag_star=.true.

     rand = sprng(stream(id))
     ! Choix de l'�toile
     call select_etoile(lambda,rand,i_star)
     ! Emission depuis l'�toile
     rand  = sprng(stream(id))
     rand2 = sprng(stream(id))
     rand3 = sprng(stream(id))
     rand4 = sprng(stream(id))
     call em_sphere_uniforme(i_star,rand,rand2,rand3,rand4,ri,zj,phik,x0,y0,z0,u0,v0,w0,w02)
     !call em_etoile_ponctuelle(i_star,rand,rand2,ri,zj,x0,y0,z0,u0,v0,w0,w02)

     if (w0 /= 0.0) then
        phi=modulo(atan2(v0,u0),2*real(pi,kind=db))
        phik=floor(phi/(2*pi)*real(N_az))+1
        if (phik==n_az+1) phik=n_az
     else
        phik=1
     endif

     ! Lumiere non polarisee emanant de l'etoile
     Stokes(1) = E_paquet ; Stokes(2) = 0.0 ; Stokes(3) = 0.0 ; Stokes(4) = 0.0

     !********************************************************
     ! Parametres du point chaud
     !********************************************************

     if (lspot) then
        !write(*,*) "*******************"
        !write(*,*) "*  Adding a spot  *"
        !write(*,*) "*******************"
        ! Pas tres malin ca, ca fait les calculs a chaque paquet

        !  Rapport des intensites point chaud / etoile
        hc_lk = hp * c_light / (tab_lambda(lambda)*1e-6 * kb)
        correct_spot = (exp(hc_lk/etoile(1)%T) - 1)/(exp(hc_lk/T_spot) - 1)
        !write (*,*) hc_lk

        ! Position
        z_spot = cos(theta_spot/180.*pi)
        x_spot = sin(theta_spot/180.*pi) * cos(phi_spot/180.*pi)
        y_spot = sin(theta_spot/180.*pi) * sin(phi_spot/180.*pi)

        ! Angle sous-tendu par le spot
        cos_thet_spot = sqrt(1.0 - surf_fraction_spot)

        ! Si le photon est dans le spot, on corrige l'intensite
        ! On multiplis par r_star car x0, y0, et z0 ont ete multiplies par r_star
        if (x_spot*x0+y_spot*y0+z_spot*z0  > cos_thet_spot * etoile(1)%r) then
           Stokes(1) = Stokes(1) * correct_spot
        else
           Stokes(1) = Stokes(1) * 1e-20
        endif
     endif ! lspot

  else ! Emission depuis le disque
     flag_star=.false.

     ! Position initiale
     rand = sprng(stream(id))
     call select_cellule(lambda,rand,ri,zj,phik)

     rand  = sprng(stream(id))
     rand2 = sprng(stream(id))
     rand3 = sprng(stream(id))
     call  pos_em_cellule(ri,zj,phik,rand,rand2,rand3,x0,y0,z0)


     ! Direction de vol (uniforme)
     rand = sprng(stream(id))
     W0 = 2.0 * rand - 1.0
     W02 =  1.0 - W0*W0
     SRW02 = sqrt (  W02 )
     rand = sprng(stream(id))
     ARGMT = PI * ( 2.0 * rand - 1.0 )
     U0 = SRW02 * cos(ARGMT)
     V0 = SRW02 * sin(ARGMT)

     ! Parametres de stokes : lumi�re non polaris�e
     Stokes(1) = E_paquet ; Stokes(2) = 0.0 ; Stokes(3) = 0.0 ; Stokes(4) = 0.0

     if (lweight_emission) Stokes(1) = Stokes(1) * correct_E_emission(ri,zj)
  endif !(rand < prob_E_star)


end subroutine emit_packet

!***********************************************************

subroutine propagate_packet(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)
  ! C. Pinte
  ! 27/05/09


  ! - flag_star_direct et flag_scatt a initialiser : on a besoin des 2
  ! - separer 1ere diffusion et reste
  ! - lom supprime !

  integer, intent(in) :: id
  integer, intent(inout) :: lambda, ri, zj, phik
  real(kind=db), intent(inout) :: x,y,z,u,v,w
  real(kind=db), dimension(4), intent(inout) :: stokes

  logical, intent(inout) :: flag_star
  logical, intent(out) :: flag_scatt, lpacket_alive

  real(kind=db) :: u1,v1,w1, phi, cospsi, w02, srw02, argmt
  integer :: p_ri, p_zj, p_phik, taille_grain, itheta
  real :: rand, rand2, tau, dvol

  logical :: flag_direct_star, flag_sortie

  flag_scatt = .false.
  flag_sortie = .false.
  flag_direct_star = .false.
  p_ri = 1 ; p_zj = 1 ; p_phik = 1

  lpacket_alive=.true.

  ! On teste si le photon (stellaire) peut rencontrer le disque
  if (flag_star) then
     flag_direct_star = .true.
     ! W02 = 1.0 - w0**2 = u**2 + v**2
     if (1.0_db - w*w < cos_max2) return ! Pas de diffusion
  endif


  ! Boucle sur les interactions du paquets:
  ! - on avance le paquet
  ! - on le fait interagir avec la poussiere si besoin
  infinie : do

     ! Longueur de vol
     rand = sprng(stream(id))
     if (rand == 1.0) then
        tau=1.0e30
     else if (rand > 1.0e-6) then
        tau = -log(1.0-rand)
     else
        tau = rand
     endif

     ! Propagation du packet jusqu'a la prochaine interaction
     !if (.not.letape_th) then
     !   if (.not.flag_star) Stokes=0.
     !endif
     call length_deg2(id,lambda,Stokes,ri,zj,phik,x,y,z,u,v,w,flag_star,flag_direct_star,tau,dvol,flag_sortie)
     if ((ri==0).and.(.not.flag_sortie)) write(*,*) "PB r", ri, zj
     if ((zj > nz).and.(.not.flag_sortie)) write(*,*) "PB z", ri, zj, abs(z)

     ! Le photon est-il encore dans la grille ?
     if (flag_sortie) return ! Vie du photon terminee

     if (lstrat) then ! TODO : pointeurs, alloue dans openMP ????
        p_ri=ri
        p_zj=zj
        if (l3D) p_phik = phik
     endif

     ! Sinon la vie du photon continue : il y a interaction
     ! Diffusion ou absorption
     flag_direct_star = .false.
     if (lmono) then   ! Diffusion forcee : on multiplie l'energie du packet par l'albedo
        ! test zone noire
        if (test_dark_zone(ri,zj,phik,x,y)) then ! on saute le photon
           lpacket_alive = .false.
           return
        endif

        ! Multiplication par albedo
        Stokes(:)=Stokes(:)*tab_albedo_pos(lambda,p_ri,p_zj,p_phik)
        if (Stokes(1) < tiny_real_x1e6)then ! on saute le photon
           lpacket_alive = .false.
           return
        endif

        ! Diffusion forcee: rand < albedo
        rand = -1.0
     else ! Choix absorption ou diffusion
        rand = sprng(stream(id))
     endif ! lmono

     if (rand < tab_albedo_pos(lambda,p_ri,p_zj,p_phik)) then ! Diffusion
        flag_scatt=.true.
        flag_direct_star = .false.

        if (lscattering_method1) then ! methode 1 : choix du grain diffuseur
           rand = sprng(stream(id))
           taille_grain = grainsize(lambda,rand,p_ri,p_zj,p_phik)
           rand = sprng(stream(id))
           rand2 = sprng(stream(id))
           if (lmethod_aniso1) then ! fonction de phase de Mie
              call angle_diff_theta(lambda,taille_grain,rand,rand2,itheta,cospsi)
              if (lisotropic)  then ! Diffusion isotrope
                 itheta=1
                 cospsi=2.0*rand-1.0
              endif
              rand = sprng(stream(id))
              !  call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
              PHI = PI * ( 2.0 * rand - 1.0 )
              ! direction de propagation apres diffusion
              call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
              if (lsepar_pola) then
                 ! Nouveaux param�tres de Stokes
                 if (laggregate) then
                    call new_stokes_gmm(lambda,itheta,rand2,taille_grain,u,v,w,u1,v1,w1,stokes)
                 else
                    call new_stokes(lambda,itheta,rand2,taille_grain,u,v,w,u1,v1,w1,stokes)
                 endif
              endif
           else ! fonction de phase HG
              call hg(lambda, tab_g(lambda,taille_grain),rand, itheta, COSPSI) !HG
              if (lisotropic) then ! Diffusion isotrope
                 itheta=1
                 cospsi=2.0*rand-1.0
              endif
              rand = sprng(stream(id))
              !  call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
              PHI = PI * ( 2.0 * rand - 1.0 )
              ! direction de propagation apres diffusion
              call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
              ! Param�tres de Stokes non modifi�s
           endif

        else ! methode 2 : diffusion sur la population de grains
           rand = sprng(stream(id))
           rand2= sprng(stream(id))
           if (lmethod_aniso1) then ! fonction de phase de Mie
              call angle_diff_theta_pos(lambda,p_ri,p_zj, p_phik, rand, rand2, itheta, cospsi)
              if (lisotropic) then ! Diffusion isotrope
                 itheta=1
                 cospsi=2.0*rand-1.0
              endif
              rand = sprng(stream(id))
              ! call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
              PHI = PI * ( 2.0 * rand - 1.0 )
              ! direction de propagation apres diffusion
              call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
              ! Nouveaux param�tres de Stokes
              if (lsepar_pola) call new_stokes_pos(lambda,itheta,rand2,p_ri,p_zj, p_phik,u,v,w,u1,v1,w1,Stokes)
           else ! fonction de phase HG
              call hg(lambda, tab_g_pos(lambda,p_ri,p_zj, p_phik),rand, itheta, cospsi) !HG
              if (lisotropic)  then ! Diffusion isotrope
                 itheta=1
                 cospsi=2.0*rand-1.0
              endif
              rand = sprng(stream(id))
              ! call angle_diff_phi(l,STOKES(1),STOKES(2),STOKES(3),itheta,rand,phi)
              phi = pi * ( 2.0 * rand - 1.0 )
              ! direction de propagation apres diffusion
              call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
              ! Param�tres de Stokes non modifi�s
           endif
        endif

        ! Mise a jour direction de vol
        u = u1 ; v = v1 ; w = w1

     else ! Absorption
        if (.not.lmono) then
           ! fraction d'energie absorbee par les grains hors equilibre
           E_abs_nRE = E_abs_nRE + Stokes(1) * (1.0 - proba_abs_RE(lambda,ri, zj, p_phik))
           ! Multiplication par proba abs sur grain en eq. radiatif
           Stokes = Stokes * proba_abs_RE(lambda,ri, zj, p_phik)

           if (Stokes(1) < tiny_real)  then ! on saute le photon
              lpacket_alive = .false.
              return
           endif
        endif

        flag_star=.false.
        flag_scatt=.false.
        flag_direct_star = .false.
        rand = sprng(stream(id))

        ! Choix longueur d'onde
        if (lRE_LTE) call reemission(id,ri,zj,phik,p_ri,p_zj,p_phik,Stokes(1),rand,lambda)
        if (lRE_nLTE) then
           rand2 = sprng(stream(id))
           call reemission_NLTE(id,ri,zj,p_ri,p_zj,Stokes(1),rand,rand2,lambda)
        endif

        ! Nouvelle direction de vol : emission uniforme
        rand = sprng(stream(id))
        w = 2.0 * rand - 1.0
        w02 =  1.0 - w*w
        srw02 = sqrt (w02)
        rand = sprng(stream(id))
        argmt = pi * ( 2.0 * rand - 1.0 )
        u = srw02 * cos(argmt)
        v = srw02 * sin(argmt)

        ! Emission non polaris�e : remise � 0 des parametres de Stokes
        Stokes(2)=0.0 ; Stokes(3)=0.0 ; Stokes(4)=0.0
     endif ! tab_albedo_pos

  enddo infinie

  write(*,*) "BUG propagate_packet"
  return

end subroutine propagate_packet

!***********************************************************

subroutine force_1st_scatt(id,lambda,ri,zj,phik,x,y,z,u,v,w,stokes,flag_star,flag_scatt,lpacket_alive)


  integer, intent(in) :: id
  integer, intent(inout) :: lambda, ri, zj, phik
  real(kind=db), intent(inout) :: x,y,z,u,v,w
  real(kind=db), dimension(4), intent(inout) :: stokes

  logical, intent(inout) :: flag_star
  logical, intent(out) :: flag_scatt, lpacket_alive

  logical :: flag_sortie, flag_direct_star

  integer :: p_ri, p_zj, p_phik, ri_save, zj_save, phik_save, taille_grain, itheta
  real :: tau_max, rand, rand2, tau, dvol
  real(kind=db) :: frac_transmise, frac_diff, x_save, y_save, z_save, lmin, lmax, frac
  real(kind=db) :: u1,v1,w1, phi, cospsi, w02, srw02, argmt
  real(kind=db), dimension(4) :: Stokes_old


  flag_scatt = .false.
  flag_sortie = .false.
  flag_direct_star = .false.
  p_ri = 1 ; p_zj = 1 ; p_phik = 1

  lpacket_alive=.true.

  ! On teste si le photon (stellaire) peut rencontrer le disque
  if (flag_star) then
     flag_direct_star = .true.
     if (1.0_db - w*w < cos_max2) return ! Pas de diffusion
  endif

  ! Cas optiquement mince : on force la premiere diffusion
  call length_deg2_tot(id,lambda,stokes,ri,zj,x,y,z,u,v,w,tau_max,lmin,lmax)

  if (tau_max < 10.) then
     ! Sauvegarde �nergie
     Stokes_old(:) = Stokes(:)

     ! fraction transmise
     frac_transmise = exp(-tau_max)
     Stokes(:) = frac_transmise * Stokes_old(:)
     if (Stokes(1) > 1.0e-30) call capteur(id,lambda,ri,zj,x,y,z,u,v,w,Stokes,flag_star,flag_scatt)

     ! tau_max=0.0 --> pas de diff
     if (tau_max >  tiny_real) then
        ! fraction diffus�e
        flag_scatt = .true.
        frac_diff = 1.0_db-frac_transmise
        if (frac_diff < 1.0e-6)  frac_diff = tau_max ! On fait un DL de l'exponentielle
        Stokes(:) = frac_diff * Stokes_old(:)

        rand = sprng(stream(id))
        frac = frac_diff*rand
        if (frac==1.0) then
           tau=1.0e30
        else if (frac > 1.0e-6) then
           tau = -log(1.0_db-frac)
        else ! on fait un DL pour ne pas avoir tau=0
           tau = tau_max * rand
        endif

        ! Tout le paquet qui va diffuse continue jusqu'au point de diffusion
        call length_deg2(id,lambda,Stokes_old,ri,zj,phik,x,y,z,u,v,w,flag_star,flag_direct_star,tau,dvol,flag_sortie)

        if (lstrat) then
           p_ri=ri
           p_zj=zj
           if (l3D) p_phik = phik
        endif


        ! Le photon est-il encore dans la grille ?
        if (flag_sortie) then
           ! TODO : ce cas ne doit normalement pas arriver
           ! TODO : il faut faire quelque chose ici
           return ! Vie du photon terminee
        endif

        ! Sinon la vie du photon continue : il y a interaction
        ! Diffusion ou absorption
        flag_direct_star = .false.
        if (lmono) then   ! Diffusion forcee : on multiplie l'energie du packet par l'albedo
           ! test zone noire
           if (test_dark_zone(ri,zj,phik,x,y)) then ! on saute le photon
              lpacket_alive = .false.
              return
           endif

           ! Multiplication par albedo
           Stokes(:)=Stokes(:)*tab_albedo_pos(lambda,p_ri,p_zj,p_phik)
           if (Stokes(1) < tiny_real_x1e6)then ! on saute le photon
              lpacket_alive = .false.
              return
           endif

           ! Diffusion forcee: rand < albedo
           rand = -1.0
        else ! Choix absorption ou diffusion
           rand = sprng(stream(id))
        endif ! lmono

        if (rand < tab_albedo_pos(lambda,p_ri,p_zj,p_phik)) then ! Diffusion
           flag_scatt=.true.
           flag_direct_star = .false.

           if (lscattering_method1) then ! methode 1 : choix du grain diffuseur
              rand = sprng(stream(id))
              taille_grain = grainsize(lambda,rand,p_ri,p_zj,p_phik)
              rand = sprng(stream(id))
              rand2 = sprng(stream(id))
              if (lmethod_aniso1) then ! fonction de phase de Mie
                 call angle_diff_theta(lambda,taille_grain,rand,rand2,itheta,cospsi)
                 if (lisotropic) then ! Diffusion isotrope
                    itheta=1
                    cospsi=2.0*rand-1.0
                 endif
                 rand = sprng(stream(id))
                 !  call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
                 PHI = PI * ( 2.0 * rand - 1.0 )
                 ! direction de propagation apres diffusion
                 call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
                 if (lsepar_pola) then
                    ! Nouveaux param�tres de Stokes
                    if (laggregate) then
                       call new_stokes_gmm(lambda,itheta,rand2,taille_grain,u,v,w,u1,v1,w1,stokes)
                    else
                       call new_stokes(lambda,itheta,rand2,taille_grain,u,v,w,u1,v1,w1,stokes)
                    endif
                 endif
              else ! fonction de phase HG
                 call hg(lambda, tab_g(lambda,taille_grain),rand, itheta, COSPSI) !HG
                 if (lisotropic) then ! Diffusion isotrope
                    itheta=1
                    cospsi=2.0*rand-1.0
                 endif
                 rand = sprng(stream(id))
                 !  call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
                 PHI = PI * ( 2.0 * rand - 1.0 )
                 ! direction de propagation apres diffusion
                 call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
                 ! Param�tres de Stokes non modifi�s
              endif

           else ! methode 2 : diffusion sur la population de grains
              rand = sprng(stream(id))
              rand2= sprng(stream(id))
              if (lmethod_aniso1) then ! fonction de phase de Mie
                 call angle_diff_theta_pos(lambda,p_ri,p_zj, p_phik, rand, rand2, itheta, cospsi)
                 if (lisotropic) then ! Diffusion isotrope
                     itheta=1
                     cospsi=2.0*rand-1.0
                  endif
                  rand = sprng(stream(id))
                 ! call angle_diff_phi(l,Stokes(1),Stokes(2),Stokes(3),itheta,rand,phi)
                 PHI = PI * ( 2.0 * rand - 1.0 )
                 ! direction de propagation apres diffusion
                 call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
                 ! Nouveaux param�tres de Stokes
                 if (lsepar_pola) call new_stokes_pos(lambda,itheta,rand2,p_ri,p_zj, p_phik,u,v,w,u1,v1,w1,Stokes)
              else ! fonction de phase HG
                 call hg(lambda, tab_g_pos(lambda,p_ri,p_zj, p_phik),rand, itheta, cospsi) !HG
                 if (lisotropic)  then ! Diffusion isotrope
                    itheta=1
                    cospsi=2.0*rand-1.0
                 endif
                 rand = sprng(stream(id))
                 ! call angle_diff_phi(l,STOKES(1),STOKES(2),STOKES(3),itheta,rand,phi)
                 phi = pi * ( 2.0 * rand - 1.0 )
                 ! direction de propagation apres diffusion
                 call cdapres(cospsi, phi, u, v, w, u1, v1, w1)
                 ! Param�tres de Stokes non modifi�s
              endif
           endif

           ! Mise a jour direction de vol
           u = u1 ; v = v1 ; w = w1

        else ! Absorption
           if (.not.lmono) then
              ! fraction d'energie absorbee par les grains hors equilibre
              E_abs_nRE = E_abs_nRE + Stokes(1) * (1.0 - proba_abs_RE(lambda,ri, zj, p_phik))
              ! Multiplication par proba abs sur grain en eq. radiatif
              Stokes = Stokes * proba_abs_RE(lambda,ri, zj, p_phik)

              if (Stokes(1) < tiny_real)  then ! on saute le photon
                 lpacket_alive = .false.
                 return
              endif
           endif

           flag_star=.false.
           flag_scatt=.false.
           flag_direct_star = .false.
           rand = sprng(stream(id))

           ! Choix longueur d'onde
           if (lRE_LTE) call reemission(id,ri,zj,phik,p_ri,p_zj,p_phik,Stokes(1),rand,lambda)
           if (lRE_nLTE) then
              rand2 = sprng(stream(id))
              call reemission_NLTE(id,ri,zj,p_ri,p_zj,Stokes(1),rand,rand2,lambda)
           endif

           ! Nouvelle direction de vol : emission uniforme
           rand = sprng(stream(id))
           w = 2.0 * rand - 1.0
           w02 =  1.0 - w*w
           srw02 = sqrt (w02)
           rand = sprng(stream(id))
           argmt = pi * ( 2.0 * rand - 1.0 )
           u = srw02 * cos(argmt)
           v = srw02 * sin(argmt)

           ! Emission non polaris�e : remise � 0 des parametres de Stokes
           Stokes(2)=0.0 ; Stokes(3)=0.0 ; Stokes(4)=0.0
        endif ! tab_albedo_pos



        if ((lscatt_ray_tracing).and.(flag_sortie)) then
           ! On sauve
           x_save = x ; y_save = y; z_save = z
           ri_save = ri ; zj_save = zj ; phik_save = phik

           ! Seule la fraction transmise contribue apres la diffusion
           tau = 1.0e30 ! On integre jusqu'au bout
           Stokes_old(:) = Stokes_old(:)*frac_transmise
           call length_deg2(id,lambda,Stokes_old,ri,zj,phik,x,y,z,u,v,w,flag_star,flag_direct_star,tau,dvol,flag_sortie)

           ! On restaure
           x = x_save ; y = y_save ; z = z_save
           ri = ri_save ; zj = zj_save ; phik = phik_save
           flag_sortie = .true.
        endif
     else ! tau_max = 0.
        lpacket_alive = .false.  ! on a deja compter le paquet donc on le tue
        return
     endif
  endif ! tau_max < 10

  return

end subroutine force_1st_scatt

!***********************************************************

subroutine dust_map(lambda,ibin)
  ! Creation de la carte d'emission de la poussiere
  ! par ray-tracing dans une direction donnee
  ! C. Pinte
  ! 24/01/08

  implicit none

#include "sprng_f.h"

  integer, intent(in) :: lambda, ibin
  real(kind=db) :: uv, u,v,w

  real(kind=db), dimension(3) :: uvw, x_plan_image, x, y_plan_image, center, dx, dy, Icorner
  real(kind=db), dimension(3,nb_proc) :: pixelcorner

  real(kind=db) :: taille_pix, x1, y1, z1, x2, y2, z2, l, x0, y0, z0
  integer :: i,j, id, igridx_max, n_iter_max, n_iter_min, ri_RT, phi_RT, nethod, ech_method, cx, cy, k


  integer, parameter :: n_rad_RT = 100, n_phi_RT = 30  ! OK, ca marche avec n_rad_RT = 1000
  real(kind=db), dimension(n_rad_RT) :: tab_r
  real(kind=db) :: rmin_RT, rmax_RT, fact_r, r, phi, fact_A, cst_phi

  if (lmono0) write(*,'(a16, $)') " Ray-tracing ..."

  phi_RT = 0.

  ! Direction de visee pour le ray-tracing
  uv = sin(tab_RT_incl(ibin) * deg_to_rad) ;  w = cos(tab_RT_incl(ibin) * deg_to_rad)
  u = uv * cos(phi_RT * deg_to_rad) ; v = uv * sin(phi_RT * deg_to_rad) ;
  uvw = (/u,v,w/)

  ! Definition des vecteurs de base du plan image dans le repere universel

  ! Vecteur x image sans PA : il est dans le plan (x,y) et orthogonal a uvw
  x = (/sin(phi_RT * deg_to_rad),-cos(phi_RT * deg_to_rad),0/)

  ! Vecteur x image avec PA
  if (abs(ang_disque) > tiny_real) then
     ! Todo : on peut faire plus simple car axe rotation perpendiculaire a x
     x_plan_image = rotation_3d(uvw, ang_disque, x)
  else
     x_plan_image = x
  endif

  ! Vecteur y image avec PA : orthogonal a x_plan_image et uvw
  y_plan_image =cross_product(x_plan_image, uvw)

  ! position initiale hors modele (du cote de l'observateur)
  ! = centre de l'image
  l = 10.*Rmax  ! on se met loin

  x0 = u * l  ;  y0 = v * l  ;  z0 = w * l
  center(1) = x0 ; center(2) = y0 ; center(3) = z0

  ! Coin en bas gauche de l'image
  Icorner(:) = center(:) -  (0.5 * map_size / zoom) * (x_plan_image + y_plan_image)

  ! Methode 1 = echantillonage log en r et uniforme en phi
  ! Methode 2 = echantillonage lineaire des pixels (carres donc) avec iteration sur les sous-pixels
  if (lsed) then
     ech_method = RT_sed_method
  else ! image
     ech_method = 2
  endif

  if (ech_method==1) then
     ! Pas de sous-pixel car les pixels ne sont pas carres
     n_iter_min = 1
     n_iter_max = 1

     dx(:) = 0.0_db
     dy(:) = 0.0_db
     i = 1
     j = 1

     rmin_RT = 0.01_db * Rmin
     rmax_RT = 2.0_db * Rmax

     tab_r(1) = rmin_RT
     fact_r = exp( (1.0_db/(real(n_rad_RT,kind=db) -1))*log(rmax_RT/rmin_RT) )

     do ri_RT = 2, n_rad_RT
        tab_r(ri_RT) = tab_r(ri_RT-1) * fact_r
     enddo

     fact_A = sqrt(pi * (fact_r - 1.0_db/fact_r)  / n_phi_RT )

     if (l_sym_ima) then
        cst_phi = pi  / real(n_phi_RT,kind=db)
     else
        cst_phi = deux_pi  / real(n_phi_RT,kind=db)
     endif

     ! Boucle sur les rayons d'echantillonnage
     !$omp parallel &
     !$omp default(none) &
     !$omp private(ri_RT,id,r,taille_pix,phi_RT,phi,pixelcorner) &
     !$omp shared(tab_r,fact_A,x_plan_image,y_plan_image,center,dx,dy,u,v,w,i,j,ibin) &
     !$omp shared(n_iter_min,n_iter_max,lambda,l_sym_ima,cst_phi)
     id =1 ! pour code sequentiel

     !$omp do schedule(dynamic,1)
     do ri_RT=1, n_rad_RT
        !$ id = omp_get_thread_num() + 1

        r = tab_r(ri_RT)
        taille_pix =  fact_A * r ! racine carree de l'aire du pixel

        do phi_RT=1,n_phi_RT ! de 0 a pi
           phi = cst_phi * (real(phi_RT,kind=db) -0.5_db)

           pixelcorner(:,id) = center(:) + r * sin(phi) * x_plan_image + r * cos(phi) * y_plan_image ! C'est le centre en fait car dx = dy = 0.
           call intensite_pixel_dust(id,ibin,n_iter_min,n_iter_max,lambda,i,j,pixelcorner(:,id),taille_pix,dx,dy,u,v,w)
        enddo !j
     enddo !i
     !$omp end do
     !$omp end parallel

  else ! method 2 : echantillonnage lineaire avec sous-pixels

     ! Vecteurs definissant les pixels (dx,dy) dans le repere universel
     taille_pix = (map_size/ zoom) / real(max(igridx,igridy),kind=db) ! en AU
     dx(:) = x_plan_image * taille_pix
     dy(:) = y_plan_image * taille_pix

     if (l_sym_ima) then
        igridx_max = igridx/2 + modulo(igridx,2)
     else
        igridx_max = igridx
     endif

     ! Boucle sur les pixels de l'image
     !$omp parallel &
     !$omp default(none) &
     !$omp private(i,j,id) &
     !$omp shared(Icorner,lambda,pixelcorner,dx,dy,u,v,w,taille_pix,igridx_max,igridy,n_iter_min,n_iter_max,ibin)
     id =1 ! pour code sequentiel
     n_iter_min = 2
     n_iter_max = 6

     !$omp do schedule(dynamic,1)
     do i = 1, igridx_max
        !$ id = omp_get_thread_num() + 1
        do j = 1,igridy
           ! Coin en bas gauche du pixel
           pixelcorner(:,id) = Icorner(:) + (i-1) * dx(:) + (j-1) * dy(:)
           call intensite_pixel_dust(id,ibin,n_iter_min,n_iter_max,lambda,i,j,pixelcorner(:,id),taille_pix,dx,dy,u,v,w)
        enddo !j
     enddo !i
     !$omp end do
     !$omp end parallel

     ! On recupere tout le flux par symetrie
     ! TODO : BUG : besoin de le faire ici ?? c'est fait dans output.f90 de toute facon ...
     if (l_sym_ima) then
        do i=igridx_max+1,igridx
           Stokes_ray_tracing(lambda,i,:,ibin,:,:) = Stokes_ray_tracing(lambda,igridx-i+1,:,ibin,:,:)
        enddo
     endif ! l_sym_image

  endif ! method

  ! Adding stellar contribution
  call compute_stars_map(lambda,ibin, u, v, w)

  id = 1
  Stokes_ray_tracing(lambda,:,:,ibin,1,id) = Stokes_ray_tracing(lambda,:,:,ibin,1,id) + stars_map
  if (lsepar_contrib) then
     Stokes_ray_tracing(lambda,:,:,ibin,n_Stokes+1,id) = Stokes_ray_tracing(lambda,:,:,ibin,n_Stokes+1,id) + stars_map
  endif

  if (lmono0) write(*,*) "Done"

  return

end subroutine dust_map

!***********************************************************

subroutine compute_stars_map(lambda,ibin, u,v,w)
  ! Make a ray-traced map of the stars

  integer, intent(in) :: lambda, ibin
  real(kind=db), intent(in) :: u,v,w

  integer, parameter :: n_ray_star = 1000

  real(kind=db), dimension(4) :: Stokes
  real(kind=db) :: facteur, x0,y0,z0, lmin, lmax, norme, x, y, z, argmt, srw02, cos_thet
  real :: rand, rand2, tau
  integer :: id, ri, zj, phik, iray, istar, i,j
  logical :: in_map

  real, dimension(:,:), allocatable :: map_1star

  stars_map = 0.0 ;
  id = 1 ;

  allocate(map_1star(igridx,igridy))

  ! Energie
  facteur = E_stars(lambda) * tab_lambda(lambda) * 1.0e-6 &
       / (distance*pc_to_AU*AU_to_Rsun)**2 * 1.35e-12

  do istar=1, n_etoiles
     map_1star = 0.0 ;

     ! Etoile ponctuelle
     !  x0=0.0_db ;  y0= 0.0_db ; z0= 0.0_db
     !  Stokes = 0.0_db
     !  call length_deg2_tot(1,lambda,Stokes,i,j,x0,y0,z0,u,v,w,tau,lmin,lmax)
     !  Flux_etoile =  exp(-tau)
     !  write(*,*)  "F0", Flux_etoile

     ! Etoile non ponctuelle

     norme = 0.0_db
     do iray=1,n_ray_star
        ! Position aleatoire sur la disque stellaire
        rand  = sprng(stream(id))
        rand2 = sprng(stream(id))

        ! Position de depart aleatoire sur une sphere de rayon 1
        z = 2.0_db * rand - 1.0_db
        srw02 = sqrt(1.0-z*z)
        argmt = pi*(2.0_db*rand2-1.0_db)
        x = srw02 * cos(argmt)
        y = srw02 * sin(argmt)

        cos_thet = abs(x*u + y*v + z*w) ;
        !cos_thet = 1.0_db ;

        ! Position de depart aleatoire sur une sphere de rayon r_etoile
        x0 = etoile(istar)%x + x * etoile(istar)%r
        y0 = etoile(istar)%y + y * etoile(istar)%r
        z0 = etoile(istar)%z + z * etoile(istar)%r

        Stokes = 0.0_db
        if (l3D) then
           ! Coordonnees initiale : position etoile dans la grille
           call indice_cellule_3D(x0,y0,z0,ri,zj,phik)

           call length_deg2_tot_3D(1,lambda,Stokes,ri,zj,phik,x0,y0,z0,u,v,w,tau,lmin,lmax)
        else
           ! Coordonnees initiale : position etoile dans la grille
           call indice_cellule(x0,y0,z0,ri,zj)

           call length_deg2_tot(1,lambda,Stokes,ri,zj,x0,y0,z0,u,v,w,tau,lmin,lmax)
        endif

        ! Coordonnees pixel
         if (lsed.and.(RT_sed_method == 1)) then
           i=1 ; j=1
        else
           call find_pixel(x0,y0,z0, u,v,w, i,j,in_map)
        endif

        if (in_map) map_1star(i,j) = map_1star(i,j) + exp(-tau) * cos_thet
        norme = norme + cos_thet
     enddo
     ! Normalizing map
     map_1star = map_1star * (facteur * prob_E_star(lambda,istar)) / norme

     ! Adding all the stars
     stars_map = stars_map + map_1star
  enddo ! n_stars

  return

end subroutine compute_stars_map

!***********************************************************

subroutine intensite_pixel_dust(id,ibin,n_iter_min,n_iter_max,lambda,ipix,jpix,pixelcorner,pixelsize,dx,dy,u,v,w)
  ! Calcule l'intensite d'un pixel carre de taille, position et orientation arbitaires
  ! par une methode de Ray-tracing
  ! (u,v,w) pointe vers l'observateur
  ! TODO : Integration par methode de Romberg pour determiner le nbre de sous-pixel
  ! necessaire
  ! Unite : W.m-2 : nu.F_nu
  ! C. Pinte
  ! 12/04/07

  implicit none

  integer, intent(in) :: lambda, ibin, ipix,jpix,id, n_iter_min, n_iter_max
  real(kind=db), dimension(3), intent(in) :: pixelcorner,dx,dy
  real(kind=db), intent(in) :: pixelsize,u,v,w

  real(kind=db), dimension(N_type_flux) :: Stokes, Stokes_old

  real(kind=db) :: x0,y0,z0,u0,v0,w0, npix2
  real(kind=db), dimension(3) :: sdx, sdy

  real(kind=db), parameter :: precision = 1.e-2_db
  integer :: i, j, subpixels, ri, zj, phik, iter

  logical :: lintersect

  ! TODO : il y a un truc bizarre dans cette routine !!!

  ! Ray tracing : on se propage dans l'autre sens
  u0 = -u ; v0 = -v ; w0 = -w

  ! le nbre de subpixel en x est 2^(iter-1)
  subpixels = 1
  iter = 1

  infinie : do ! boucle jusqu'a convergence

     npix2 =  real(subpixels)**2
     Stokes_old(:) = Stokes(:)
     Stokes(:) = 0.0_db

     ! Vecteurs definissant les sous-pixels
     sdx(:) = dx(:) / real(subpixels,kind=db)
     sdy(:) = dy(:) / real(subpixels,kind=db)

     ! L'obs est en dehors de la grille
     ri = 2*n_rad ; zj=1 ; phik=1

     ! Boucle sur les sous-pixels qui calcule l'intensite au centre
     ! de chaque sous pixel
     do i = 1,subpixels
        do j = 1,subpixels
           ! Centre du sous-pixel
           x0 = pixelcorner(1) + (i - 0.5_db) * sdx(1) + (j-0.5_db) * sdy(1)
           y0 = pixelcorner(2) + (i - 0.5_db) * sdx(2) + (j-0.5_db) * sdy(2)
           z0 = pixelcorner(3) + (i - 0.5_db) * sdx(3) + (j-0.5_db) * sdy(3)

           ! On se met au bord de la grille : propagation a l'envers
           call move_to_grid(x0,y0,z0,u0,v0,w0,ri,zj,phik,lintersect)  !BUG
           if (lintersect) then ! On rencontre la grille, on a potentiellement du flux
              ! Flux recu dans le pixel
             ! write(*,*) i,j,  integ_ray_dust(id,lambda,ri,zj,phik,x0,y0,z0,u0,v0,w0)
              !write(*,*) "pixel"
              Stokes(:) = Stokes(:) +  integ_ray_dust(id,lambda,ri,zj,phik,x0,y0,z0,u0,v0,w0)
           endif
        enddo !j
     enddo !i
     Stokes(:) = Stokes(:) / npix2

     if (iter < n_iter_min) then
        ! On itere par defaut
        subpixels = subpixels * 2
     else if (iter >= n_iter_max) then
        ! On arrete pour pas tourner dans le vide
        ! write(*,*) "Warning : converging pb in ray-tracing"
        ! write(*,*) " Pixel", ipix, jpix
        exit infinie
     else
        ! On fait le test sur a difference
        if (abs(Stokes(1) - Stokes_old(1)) > precision * Stokes_old(1)) then
           ! On est pas converge
           subpixels = subpixels * 2
        else
           ! On est converge
           exit infinie
        endif
     endif ! iter

     iter = iter + 1

  enddo infinie

  ! Prise en compte de la surface du pixel (en sr)
  Stokes = Stokes * (pixelsize / (distance*pc_to_AU) )**2

  if (lsed) then
     ! Sommation sur les pixels implicite
     Stokes_ray_tracing(lambda,ipix,jpix,ibin,:,id) = Stokes_ray_tracing(lambda,ipix,jpix,ibin,:,id) + Stokes(:)
  else
     Stokes_ray_tracing(lambda,ipix,jpix,ibin,:,id) = Stokes(:)
  endif

  return

end subroutine intensite_pixel_dust

!***********************************************************

!!$subroutine flux_ray_tracing(lambda,u,v,w)
!!$  ! Creation de la carte d'emission de la poussiere
!!$  ! par ray-tracing dans une direction donnee
!!$  ! C. Pinte
!!$  ! 24/01/08
!!$
!!$  implicit none
!!$
!!$  integer, intent(in) :: lambda
!!$  real(kind=db), intent(in) :: u,v,w
!!$
!!$  real(kind=db) :: u0, v0, w0, r, x0, y0, z0, w02, phi, l, dA_surface, dA_tranche, dA, lmin, lmax
!!$  real :: tau
!!$  integer :: i, j, phi_RT, ri, zj, phik, id
!!$  real(kind=db), dimension(4) :: Stokes
!!$
!!$  logical :: lintersect
!!$
!!$  integer, parameter :: n_phi_RT = 4
!!$
!!$  write(*,'(a16, $)') " Ray-tracing NEW ..."
!!$
!!$  Stokes(:) = 0.0_db
!!$
!!$  id = 1 ! TMP
!!$
!!$  u0 = -u ; v0 = -v ; w0 = -w
!!$  w02 = sqrt(1.0_db - w*w)
!!$
!!$  ! position initiale hors modele (du cote de l'observateur)
!!$  l = 10.*rout  ! on se met loin
!!$
!!$  ! Boucle sur les cellules
!!$  do i=1, n_rad_RT
!!$
!!$
!!$
!!$     dA_surface = pi * dr2_grid(i)
!!$     dA_tranche = deux_pi * r_grid(i,j) * delta_z(i)
!!$     dA = dA_surface * w + dA_tranche * w02
!!$     dA = 2.0_db * dA / real(n_phi_RT,kind=db)
!!$
!!$     dA = 1.0
!!$
!!$     do phi_RT = 1, n_phi_RT
!!$
!!$        phi = pi * real(phi_RT,kind=db) / real(n_phi_RT,kind=db)
!!$
!!$        ! Position physique dans le disque
!!$        z0 = z_grid(i,j)
!!$        r = r_grid(i,j)
!!$        x0 = r * cos(phi)
!!$        y0 = r * sin(phi)
!!$
!!$        ! Position de depart
!!$        x0 = x0 + u * l  ;  y0 = y0 + v * l  ;  z0 = z0 + w * l
!!$
!!$        ! L'obs est en dehors de la grille
!!$        ri = 2*n_rad ; zj=1 ; phik=1
!!$
!!$        call move_to_grid(x0,y0,z0,u0,v0,w0,ri,zj,lintersect)
!!$        if (lintersect) then ! On rencontre la grille, on a potentiellement du flux
!!$           ! Flux recu dans le pixel
!!$           Stokes(:) = Stokes(:) +  integ_ray_dust(id,lambda,ri,zj,phik,x0,y0,z0,u0,v0,w0) * dA
!!$        endif
!!$
!!$     enddo ! phi_RT
!!$  enddo ! i
!!$
!!$  ! Prise en compte de la surface
!!$  Stokes_ray_tracing(lambda,1,1,:) = Stokes(:) * (1.0_db / (distance*pc_to_AU) )**2 * 2.0e-5
!!$
!!$  ! Ajout etoile
!!$  i=0 ; j=1 ; x0=0.0_db ; y0=0.0_db ; z0=0.0_db
!!$  Stokes = 0.0_db
!!$  call length_deg2_tot(1,lambda,Stokes,i,j,x0,y0,y0,u,v,w,tau,lmin,lmax)
!!$
!!$  Flux_etoile = E_stars(lambda) * tab_lambda(lambda) * 1.0e-6 * exp(-tau) &
!!$       / (distance*pc_to_AU*AU_to_Rsun)**2 * 1.35e-12  ! ????? TODO, c'est quoi 1.35 e-12
!!$
!!$  Stokes_ray_tracing(lambda,1,1,1) = Stokes_ray_tracing(lambda,1,1,1) + Flux_etoile
!!$
!!$  write(*,*) "Done"
!!$
!!$
!!$  return
!!$
!!$end subroutine flux_ray_tracing
!!$
!!$!***********************************************************

end module dust_transfer
